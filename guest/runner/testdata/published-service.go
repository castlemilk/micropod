// Local Docker integration fixture for ci/runner-macvlan.test.sh.
package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"syscall"
	"time"
)

func main() {
	var err error
	switch os.Args[1] {
	case "serve":
		err = serve(os.Args[2])
	case "guard":
		var listener net.Listener
		listener, err = net.Listen("tcp4", net.JoinHostPort(os.Args[2], "0"))
		if err == nil {
			err = os.WriteFile(os.Args[3], []byte(listener.Addr().String()), 0600)
		}
		if err == nil {
			err = http.Serve(listener, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				fmt.Fprint(w, "host")
			}))
		}
	case "hold":
		err = hold(os.Args[2], os.Args[3], os.Args[4])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func serve(label string) error {
	dev, err := net.InterfaceByName("eth0")
	if err != nil {
		return err
	}
	addrs, err := dev.Addrs()
	if err != nil {
		return err
	}
	for _, addr := range addrs {
		ip, _, e := net.ParseCIDR(addr.String())
		if e != nil || ip.To4() == nil {
			continue
		}
		serve := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, label) })
		done := make(chan error, 2)
		for _, port := range []string{"8080", "8081"} {
			ln, e := net.Listen("tcp4", net.JoinHostPort(ip.String(), port))
			if e != nil {
				return e
			}
			go func() { done <- http.Serve(ln, serve) }()
		}
		return <-done
	}
	return errors.New("missing Docker IPv4 address")
}

// Keep the old HTTP/1.1 connection across core engine port reuse. A timeout or
// a response from either service on the retired socket fails the check.
func hold(addr, marker, dir string) error {
	c, err := net.DialTimeout("tcp4", addr, 3*time.Second)
	if err != nil {
		return err
	}
	defer c.Close()
	reader := bufio.NewReader(c)
	probe := func() (string, error) {
		c.SetDeadline(time.Now().Add(3 * time.Second))
		req, err := http.NewRequest("GET", "http://"+addr+"/id", nil)
		if err != nil {
			return "", err
		}
		if err = req.Write(c); err != nil {
			return "", err
		}
		// Preserve an orderly close before any response bytes as io.EOF.
		if _, err = reader.Peek(1); err != nil {
			return "", err
		}
		r, err := http.ReadResponse(reader, req)
		if err != nil {
			return "", err
		}
		defer r.Body.Close()
		b, err := io.ReadAll(r.Body)
		return string(b), err
	}
	got, err := probe()
	if err != nil {
		return err
	}
	if got != marker {
		return fmt.Errorf("unexpected owner %q", got)
	}
	if err = os.WriteFile(dir+"/ready", nil, 0600); err != nil {
		return err
	}
	until := time.Now().Add(25 * time.Second)
	for {
		if _, err = os.Stat(dir + "/reused"); err == nil {
			break
		}
		if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if time.Now().After(until) {
			return errors.New("port was not reused in time")
		}
		time.Sleep(20 * time.Millisecond)
	}
	got, err = probe()
	if errors.Is(err, io.EOF) || errors.Is(err, syscall.ECONNRESET) || errors.Is(err, syscall.EPIPE) {
		return nil
	}
	return fmt.Errorf("retired connection returned %q, %v", got, err)
}
