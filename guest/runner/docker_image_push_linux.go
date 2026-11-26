package main

import (
	"bytes"
	"cmp"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"

	images "github.com/containerd/containerd/api/services/images/v1"
	transfer "github.com/containerd/containerd/api/types/transfer"
	"github.com/distribution/reference"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type imagePushTarget struct {
	source    string
	ref       reference.NamedTagged
	digest    string
	ambiguous bool
}

type dockerPushMessage struct {
	Status         string              `json:"status,omitempty"`
	ID             string              `json:"id,omitempty"`
	ProgressDetail *dockerPushProgress `json:"progressDetail,omitempty"`
	Error          string              `json:"error,omitempty"`
	ErrorDetail    *dockerPushError    `json:"errorDetail,omitempty"`
	Aux            *dockerPushResult   `json:"aux,omitempty"`
}

type dockerPushProgress struct {
	Current int64 `json:"current"`
	Total   int64 `json:"total"`
}

type dockerPushError struct {
	Message string `json:"message"`
}

type dockerPushResult struct {
	Tag    string
	Digest string
	Size   int64
}

func (s *dockerEngine) pushImage(w http.ResponseWriter, r *http.Request, raw string) error {
	q, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil || len(q["tag"]) > 1 || len(q["platform"]) > 1 {
		return fail(http.StatusBadRequest, "invalid image push parameters")
	}
	if q.Get("platform") != "" {
		return fail(http.StatusNotImplemented, "platform-specific image push is unavailable")
	}
	ref, err := imagePushReference(raw, q.Get("tag"))
	if err != nil {
		return err
	}
	config, err := imageRegistryCredentials(w, r, reference.Domain(ref))
	if err != nil {
		return err
	}
	if config.RegistryToken != "" {
		return fail(http.StatusNotImplemented, "direct registry token authentication is unavailable")
	}
	credentials := registryPushCredentials{}
	switch {
	case config.IdentityToken != "":
		credentials = registryPushCredentials{kind: transfer.AuthType_REFRESH, secret: config.IdentityToken}
	case config.Username != "":
		credentials = registryPushCredentials{kind: transfer.AuthType_CREDENTIALS, username: config.Username, secret: config.Password}
	}
	targets, err := s.node.imagePushTargets(r.Context(), ref)
	if err != nil {
		return err
	}
	if len(targets) == 0 {
		return fail(http.StatusNotFound, "no local image tag for "+reference.FamiliarString(ref))
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Connection", "close")
	encoder := json.NewEncoder(w)
	controller := http.NewResponseController(w)
	var writeErr error
	write := func(message dockerPushMessage) error {
		_ = controller.SetWriteDeadline(time.Now().Add(30 * time.Second))
		writeErr = encoder.Encode(message)
		if writeErr == nil {
			writeErr = controller.Flush()
		}
		_ = controller.SetWriteDeadline(time.Time{})
		return writeErr
	}
	defer func() { _ = controller.SetWriteDeadline(time.Now().Add(30 * time.Second)) }()
	if write(dockerPushMessage{Status: "The push refers to repository [" + ref.Name() + "]"}) != nil {
		return nil
	}
	for _, target := range targets {
		result, err := s.node.imagePush.push(r.Context(), target, credentials, &s.imageMu, func(progress *transfer.Progress) error {
			msg, ok := imagePushProgress(progress)
			if !ok {
				return nil
			}
			return write(msg)
		})
		if err != nil {
			if writeErr == nil && r.Context().Err() == nil {
				// Registry and transport error text can include remote response
				// bodies and URLs. Only emit messages derived from status codes.
				message := imagePushErrorMessage(err)
				_ = write(dockerPushMessage{Error: message, ErrorDetail: &dockerPushError{Message: message}})
			}
			return nil
		}
		summary := fmt.Sprintf("%s: digest: %s size: %d", result.Tag, result.Digest, result.Size)
		if write(dockerPushMessage{Status: summary}) != nil || write(dockerPushMessage{Aux: result}) != nil {
			return nil
		}
	}
	return nil
}

func imagePushReference(raw, tag string) (reference.Named, error) {
	ref, err := reference.ParseNormalizedNamed(raw)
	if err != nil || reference.FamiliarName(ref) == "sha256" {
		return nil, fail(http.StatusBadRequest, "invalid image push repository")
	}
	if _, ok := ref.(reference.Digested); ok {
		return nil, fail(http.StatusBadRequest, "cannot push a digest reference")
	}
	if tag == "" {
		return ref, nil
	}
	if named, ok := ref.(reference.Tagged); ok && named.Tag() != tag {
		return nil, fail(http.StatusBadRequest, "conflicting image push tags")
	}
	ref, err = reference.WithTag(ref, tag)
	if err != nil {
		return nil, fail(http.StatusBadRequest, "invalid image push tag")
	}
	return ref, nil
}

func (n node) imagePushTargets(ctx context.Context, ref reference.Named) ([]imagePushTarget, error) {
	ctx = imageMetadataContext(ctx)
	tagged, single := ref.(reference.NamedTagged)
	if single {
		exact, err := n.imageStore.Get(ctx, &images.GetImageRequest{Name: ref.String()})
		if err == nil {
			return []imagePushTarget{{source: exact.GetImage().GetName(), ref: tagged}}, nil
		}
		if status.Code(err) != codes.NotFound {
			return nil, fail(http.StatusServiceUnavailable, "could not read the local image store")
		}
	}

	// Imports can retain an unnormalized spelling. The transfer source must
	// use the stored name, and the destination must use the matching Docker tag.
	listed, err := n.imageStore.List(ctx, &images.ListImagesRequest{})
	if err != nil {
		return nil, fail(http.StatusServiceUnavailable, "could not list local image tags")
	}
	byName := make(map[string]imagePushTarget)
	for _, image := range listed.GetImages() {
		parsed, err := reference.ParseNormalizedNamed(image.GetName())
		name, tagged := parsed.(reference.NamedTagged)
		_, digested := parsed.(reference.Digested)
		if err != nil || !tagged || digested || name.Name() != ref.Name() || single && name.String() != ref.String() {
			continue
		}
		key := name.String()
		candidate := imagePushTarget{source: image.GetName(), ref: name, digest: image.GetTarget().GetDigest()}
		old := byName[key]
		switch {
		case old.source == key:
		case candidate.source == key || old.source == "":
			byName[key] = candidate
		case old.digest != candidate.digest:
			old.ambiguous = true
			byName[key] = old
		}
	}
	targets := make([]imagePushTarget, 0, len(byName))
	for _, candidate := range byName {
		if candidate.ambiguous {
			return nil, fail(http.StatusConflict, "ambiguous local tag "+reference.FamiliarString(candidate.ref))
		}
		targets = append(targets, candidate)
	}
	slices.SortFunc(targets, func(a, b imagePushTarget) int { return cmp.Compare(a.ref.Tag(), b.ref.Tag()) })
	return targets, nil
}

func imageRegistryCredentials(w http.ResponseWriter, r *http.Request, registry string) (dockerRegistryAuth, error) {
	invalid := fail(http.StatusBadRequest, "invalid registry authentication")
	var config dockerRegistryAuth
	var data []byte
	var err error
	if len(r.Header.Values("X-Registry-Auth")) > 1 {
		return dockerRegistryAuth{}, invalid
	}
	if value := r.Header.Get("X-Registry-Auth"); value != "" {
		data, err = base64.URLEncoding.DecodeString(value)
		if err != nil {
			data, err = base64.RawURLEncoding.DecodeString(value)
		}
	} else if r.Body != nil {
		data, err = readBody(w, r)
	}
	if err != nil || len(bytes.TrimSpace(data)) != 0 && json.Unmarshal(data, &config) != nil {
		return dockerRegistryAuth{}, invalid
	}
	if config.ServerAddress != "" && !pushAuthAddressMatches(config.ServerAddress, registry) {
		return dockerRegistryAuth{}, fail(http.StatusBadRequest, "registry authentication address does not match the image repository")
	}
	if config.Username == "" && config.Password == "" && config.Auth != "" {
		decoded, err := base64.StdEncoding.DecodeString(config.Auth)
		if err != nil {
			decoded, err = base64.RawStdEncoding.DecodeString(config.Auth)
		}
		user, password, ok := strings.Cut(string(decoded), ":")
		if err != nil || !ok || user == "" {
			return dockerRegistryAuth{}, invalid
		}
		config.Username, config.Password = user, password
	}
	if strings.Contains(config.Username, ":") || (config.Username == "" && config.Password != "") {
		return dockerRegistryAuth{}, invalid
	}
	return config, nil
}

func pushAuthAddressMatches(address, registry string) bool {
	if !strings.Contains(address, "://") {
		address = "https://" + address
	}
	u, err := url.Parse(address)
	if err != nil || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" ||
		(u.Scheme != "https" && u.Scheme != "http") || pushRegistryHost(u.Host) != pushRegistryHost(registry) {
		return false
	}
	return u.Path == "" || u.Path == "/" || pushRegistryHost(registry) == "registry-1.docker.io" && u.Path == "/v1/"
}

func imagePushProgress(p *transfer.Progress) (dockerPushMessage, bool) {
	_, digest, ok := strings.Cut(p.GetDesc().GetDigest(), ":")
	if !ok || len(digest) < 12 {
		return dockerPushMessage{}, false
	}
	msg := dockerPushMessage{ID: digest[:12]}
	switch p.GetEvent() {
	case "waiting":
		msg.Status = "Preparing"
	case "uploading":
		msg.Status = "Pushing"
		msg.ProgressDetail = &dockerPushProgress{Current: p.GetProgress(), Total: p.GetTotal()}
	case "complete":
		msg.Status = "Pushed"
	case "already exists":
		msg.Status = "Layer already exists"
	default:
		return dockerPushMessage{}, false
	}
	return msg, true
}

func imagePushErrorMessage(err error) string {
	problem := status.Convert(err)
	switch problem.Code() {
	case codes.Unauthenticated, codes.PermissionDenied:
		return "registry denied image push"
	case codes.NotFound:
		return "the local tag or required image content was not found"
	case codes.Unimplemented:
		return "the runtime does not support this image push"
	case codes.Unavailable, codes.DeadlineExceeded:
		return "the runtime or registry was unavailable during image push"
	case codes.Unknown:
		// Containerd's registry HTTP errors may cross Transfer as Unknown.
		// Recognize only the status line it constructs and its auth sentinel.
		message := problem.Message()
		line, _, _ := strings.Cut(message[:min(len(message), 4096)], "\n")
		if strings.Contains(line, "unexpected status from ") &&
			(strings.HasSuffix(line, ": 401 Unauthorized") || strings.HasSuffix(line, ": 403 Forbidden")) ||
			line == "authorization failed" || strings.HasSuffix(line, ": authorization failed") ||
			strings.HasSuffix(line, "authorization failed: no basic auth credentials") {
			return "registry denied image push"
		}
	}
	return "image push failed"
}
