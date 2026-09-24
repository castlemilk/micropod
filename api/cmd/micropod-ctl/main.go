// Command micropod-ctl is a small connect client example for the Micropod
// API. Usage: micropod-ctl list-containers | pull <ref> | run <image> <name> ...
package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"

	"connectrpc.com/connect"

	micropodv1 "github.com/castlemilk/micropod/sdk/go/gen/micropod/v1"
	"github.com/castlemilk/micropod/sdk/go/gen/micropod/v1/micropodv1connect"
)

func main() {
	base := os.Getenv("MICROPOD_API_URL")
	if base == "" {
		base = "http://127.0.0.1:45454"
	}
	client := micropodv1connect.NewMicropodServiceClient(httpClient(), base)
	ctx := context.Background()

	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: micropod-ctl <cmd> [args]")
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "system":
		var res *connect.Response[micropodv1.SystemSnapshot]
		res, err = client.GetSystem(ctx, connect.NewRequest(&micropodv1.Empty{}))
		if err == nil {
			s := res.Msg.GetStatus()
			fmt.Printf("status=%s cli=%s apiserver=%s\n", s.GetStatus(), s.GetCliVersion(), s.GetApiServerVersion())
		}
	case "list-containers", "containers":
		var res *connect.Response[micropodv1.ListContainersResponse]
		res, err = client.ListContainers(ctx, connect.NewRequest(&micropodv1.Empty{}))
		if err == nil {
			for _, c := range res.Msg.GetContainers() {
				fmt.Printf("%s\t%s\t%s\t%s\n", c.GetId(), c.GetState(), c.GetImage(), c.GetIpv4Address())
			}
		}
	case "run":
		name := ""
		if len(os.Args) > 3 {
			name = os.Args[3]
		}
		var res *connect.Response[micropodv1.ContainerRef]
		res, err = client.RunContainer(ctx, connect.NewRequest(&micropodv1.RunContainerRequest{
			Image: os.Args[2], Name: &name,
		}))
		if err == nil {
			fmt.Println(res.Msg.GetId())
		}
	case "pull":
		var stream *connect.ServerStreamForClient[micropodv1.ProgressLine]
		stream, err = client.PullImage(ctx, connect.NewRequest(&micropodv1.PullImageRequest{Reference: os.Args[2]}))
		if err == nil {
			for stream.Receive() {
				fmt.Println(stream.Msg().GetLine())
			}
			err = stream.Err()
		}
	case "stats":
		var res *connect.Response[micropodv1.GetStatsResponse]
		res, err = client.GetStats(ctx, connect.NewRequest(&micropodv1.GetStatsRequest{}))
		if err == nil {
			for _, c := range res.Msg.GetSnapshot().GetContainers() {
				fmt.Printf("%s mem=%d rx=%d pids=%d\n", c.GetId(), c.GetMemoryUsedBytes(), c.GetNetworkRxBytes(), c.GetPids())
			}
		}
	default:
		err = fmt.Errorf("unknown command %q", strings.Join(os.Args[1:], " "))
	}
	if err != nil {
		log.Fatal(err)
	}
}

func httpClient() *http.Client { return &http.Client{} }
