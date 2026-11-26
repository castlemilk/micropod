package main

import (
	"context"
	"crypto/rand"
	"errors"
	"io"
	"log"
	"strings"
	"sync"
	"time"

	leases "github.com/containerd/containerd/api/services/leases/v1"
	streaming "github.com/containerd/containerd/api/services/streaming/v1"
	transferapi "github.com/containerd/containerd/api/services/transfer/v1"
	"github.com/containerd/containerd/api/types"
	transfer "github.com/containerd/containerd/api/types/transfer"
	"github.com/distribution/reference"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/anypb"
	"google.golang.org/protobuf/types/known/emptypb"
)

type registryPushCredentials struct {
	kind     transfer.AuthType
	username string
	secret   string
}

type dockerRegistryPusher struct {
	transfer transferapi.TransferClient
	streams  streaming.StreamingClient
	leases   leases.LeasesClient
}

func newDockerRegistryPusher(conn grpc.ClientConnInterface) dockerRegistryPusher {
	return dockerRegistryPusher{
		transfer: transferapi.NewTransferClient(conn),
		streams:  streaming.NewStreamingClient(conn),
		leases:   leases.NewLeasesClient(conn),
	}
}

func (p dockerRegistryPusher) push(ctx context.Context, target imagePushTarget, auth registryPushCredentials, imageMu *sync.RWMutex, report func(*transfer.Progress) error) (*dockerPushResult, error) {
	if p.transfer == nil || p.streams == nil || p.leases == nil {
		return nil, status.Error(codes.Unavailable, "containerd image transfer is unavailable")
	}
	storeCtx := imageMetadataContext(ctx)
	leaseID := "mp-image-push-" + rand.Text()
	_, err := p.leases.Create(storeCtx, &leases.CreateRequest{ID: leaseID, Labels: map[string]string{
		"containerd.io/gc.expire": time.Now().UTC().Add(24 * time.Hour).Format(time.RFC3339),
	}})
	if err != nil {
		return nil, err
	}
	// Containerd closes the progress stream at the end of Transfer. Its auth
	// stream registration can survive a canceled transport, so lease both.
	defer func() {
		cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(storeCtx), 5*time.Second)
		defer cancel()
		if _, err := p.leases.Delete(cleanupCtx, &leases.DeleteRequest{ID: leaseID}); err != nil && status.Code(err) != codes.NotFound {
			log.Printf("containerd image push lease cleanup failed (%s)", status.Code(err))
		}
	}()
	ctx, cancel := context.WithCancel(metadata.AppendToOutgoingContext(storeCtx, "containerd-lease", leaseID))
	defer cancel()

	progressID := "docker-push-progress-" + rand.Text()
	progress, err := p.openStream(ctx, progressID)
	if err != nil {
		return nil, err
	}
	// An explicit scheme keeps certificate verification enabled on loopback,
	// too. Use the worker's system trust store and the exact destination.
	resolver := &transfer.RegistryResolver{DefaultScheme: "https"}
	var authStream streaming.Streaming_StreamClient
	if auth.kind != transfer.AuthType_NONE {
		resolver.AuthStream = "docker-push-auth-" + rand.Text()
		authStream, err = p.openStream(ctx, resolver.AuthStream)
		if err != nil {
			return nil, err
		}
	}
	// The runtime resolves this exact tag when Transfer starts and reports its
	// actual root descriptor before contacting the registry.
	source, err := registryPushAny(&transfer.ImageStore{Name: target.source})
	if err != nil {
		return nil, err
	}
	destination, err := registryPushAny(&transfer.OCIRegistry{Reference: target.ref.String(), Resolver: resolver})
	if err != nil {
		return nil, err
	}

	// Keep this engine's tag and ID writers out until the selected content
	// graph is leased. Only local selection and lease attachment hold the lock.
	imageMu.RLock()
	releaseSource := sync.OnceFunc(imageMu.RUnlock)
	defer releaseSource()
	selectionTimeout := time.AfterFunc(5*time.Second, cancel)
	defer selectionTimeout.Stop()

	var authDone chan error
	if authStream != nil {
		authDone = make(chan error, 1)
		go func() {
			err := servePushCredentials(authStream, target, auth)
			if errors.Is(err, io.EOF) || ctx.Err() != nil {
				err = nil
			} else if err != nil {
				cancel()
			}
			authDone <- err
		}()
	}
	transferDone := make(chan error, 1)
	go func() {
		_, err := p.transfer.Transfer(ctx, &transferapi.TransferRequest{
			Source: source, Destination: destination, Options: &transferapi.TransferOptions{ProgressStream: progressID},
		})
		if err != nil {
			cancel()
		}
		transferDone <- err
	}()

	result, progressErr := receivePushProgress(progress, target, func(desc *types.Descriptor) error {
		_, err := p.leases.AddResource(ctx, &leases.AddResourceRequest{ID: leaseID, Resource: &leases.Resource{
			Type: "content", ID: desc.GetDigest(),
		}})
		if err != nil {
			return err
		}
		selectionTimeout.Stop()
		releaseSource()
		return nil
	}, report)
	if progressErr != nil {
		cancel()
	}
	transferErr := <-transferDone
	cancel()
	if authDone != nil {
		if err := <-authDone; err != nil {
			return nil, err
		}
	}
	if transferErr != nil {
		return nil, transferErr
	}
	if progressErr == nil && result == nil {
		return nil, errors.New("containerd did not confirm the leased image push source")
	}
	return result, progressErr
}

func (p dockerRegistryPusher) openStream(ctx context.Context, id string) (streaming.Streaming_StreamClient, error) {
	init, err := registryPushAny(&streaming.StreamInit{ID: id})
	if err != nil {
		return nil, err
	}
	stream, err := p.streams.Stream(ctx)
	if err != nil {
		return nil, err
	}
	if err := stream.Send(init); err != nil {
		return nil, err
	}
	ack, err := stream.Recv()
	if err != nil {
		return nil, err
	}
	if err := unmarshalRegistryPushAny(ack, &emptypb.Empty{}); err != nil {
		return nil, err
	}
	return stream, nil
}

func servePushCredentials(stream streaming.Streaming_StreamClient, target imagePushTarget, credentials registryPushCredentials) error {
	registry := pushRegistryHost(reference.Domain(target.ref))
	ref := target.ref.String()
	for {
		message, err := stream.Recv()
		if err != nil {
			return err
		}
		var request transfer.AuthRequest
		if err := unmarshalRegistryPushAny(message, &request); err != nil {
			return err
		}
		response := &transfer.AuthResponse{}
		if request.GetReference() == ref && pushRegistryHost(request.GetHost()) == registry {
			response.AuthType = credentials.kind
			response.Username = credentials.username
			response.Secret = credentials.secret
		}
		message, err = registryPushAny(response)
		if err != nil {
			return err
		}
		if err := stream.Send(message); err != nil {
			return err
		}
	}
}

func pushRegistryHost(host string) string {
	host = strings.ToLower(host)
	switch host {
	case "docker.io", "index.docker.io", "registry-1.docker.io":
		return "registry-1.docker.io"
	default:
		return host
	}
}

func receivePushProgress(stream streaming.Streaming_StreamClient, target imagePushTarget, retain func(*types.Descriptor) error, report func(*transfer.Progress) error) (*dockerPushResult, error) {
	var root *types.Descriptor
	var result *dockerPushResult
	for {
		message, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			return result, nil
		}
		if err != nil {
			return nil, err
		}
		var progress transfer.Progress
		if err := unmarshalRegistryPushAny(message, &progress); err != nil {
			return nil, err
		}
		desc := progress.GetDesc()
		switch progress.GetEvent() {
		case "pushing content":
			if progress.GetName() != target.source || desc.GetDigest() == "" || desc.GetSize() < 0 ||
				root != nil && (root.GetDigest() != desc.GetDigest() || root.GetSize() != desc.GetSize()) {
				return nil, errors.New("containerd reported an invalid image push source")
			}
			if root == nil {
				if err := retain(desc); err != nil {
					return nil, err
				}
				root = desc
			}
		case "pushed content":
			if root != nil && progress.GetName() == target.source && root.GetDigest() == desc.GetDigest() && root.GetSize() == desc.GetSize() {
				result = &dockerPushResult{Tag: target.ref.Tag(), Digest: desc.GetDigest(), Size: desc.GetSize()}
			}
		}
		if root != nil {
			if err := report(&progress); err != nil {
				return nil, err
			}
		}
	}
}

// Containerd's typeurl library uses the protobuf full name without a URL prefix.
func registryPushAny(message proto.Message) (*anypb.Any, error) {
	data, err := proto.Marshal(message)
	if err != nil {
		return nil, err
	}
	return &anypb.Any{TypeUrl: string(message.ProtoReflect().Descriptor().FullName()), Value: data}, nil
}

func unmarshalRegistryPushAny(envelope *anypb.Any, message proto.Message) error {
	if envelope.GetTypeUrl() != string(message.ProtoReflect().Descriptor().FullName()) {
		return errors.New("unexpected containerd transfer message type")
	}
	return proto.Unmarshal(envelope.GetValue(), message)
}
