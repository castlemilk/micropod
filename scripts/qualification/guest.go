// An offline Linux executable shared by Docker, Buildx and OCI qualification.
package main

import (
	"errors"
	"fmt"
	"net"
	"os"
	"os/signal"
	"syscall"
)

func check(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func main() {
	args := os.Args[1:]
	switch args[0] {
	case "identity":
		dir, err := os.Getwd()
		check(err)
		host, err := os.Hostname()
		check(err)
		fmt.Printf("%d:%d|%s|%s|%s\n", os.Getuid(), os.Getgid(), dir, os.Getenv("QUALIFY"), host)
	case "build-result":
		_, err := os.Stat("/src/ignored")
		if !errors.Is(err, os.ErrNotExist) {
			fmt.Fprintln(os.Stderr, "ignored input was visible")
			os.Exit(1)
		}
		info, err := os.Stat("/src/input")
		check(err)
		data, err := os.ReadFile("/src/input")
		check(err)
		result := fmt.Sprintf("%s|%o", data, info.Mode().Perm())
		check(os.WriteFile("/result", []byte(result), 0644))
	case "read":
		data, err := os.ReadFile(args[1])
		check(err)
		_, err = os.Stdout.Write(data)
		check(err)
	case "write":
		check(os.WriteFile(args[1], []byte(args[2]), 0644))
	case "readonly":
		err := os.WriteFile(args[1], []byte("changed"), 0644)
		if !errors.Is(err, syscall.EROFS) {
			fmt.Fprintf(os.Stderr, "expected read-only filesystem, got %v\n", err)
			os.Exit(1)
		}
	case "resolve":
		ips, err := net.LookupHost(args[1])
		check(err)
		if len(ips) == 0 {
			os.Exit(1)
		}
		fmt.Println(ips[0])
	case "exit23":
		fmt.Println("guest-out")
		fmt.Fprintln(os.Stderr, "guest-err")
		os.Exit(23)
	case "hold":
		stop := make(chan os.Signal, 1)
		signal.Notify(stop, syscall.SIGTERM)
		fmt.Println("ready")
		<-stop
		fmt.Println("stopped")
	default:
		os.Exit(2)
	}
}
