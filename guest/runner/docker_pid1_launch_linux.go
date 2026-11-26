package main

import (
	"errors"
	"fmt"
	"net"
	"os"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

// This mode runs inside the container, under its OCI credentials and cgroup.
// Every non-stdio descriptor is closed before or by exec.
func launchDockerPID1(args []string) int {
	if len(args) < 3 || os.Getpid() != 1 {
		fmt.Fprintln(os.Stderr, "container console requires a PID 1 command")
		return 125
	}
	if err := installConsoleIO(args[0], args[1]); err != nil {
		fmt.Fprintln(os.Stderr, "container console:", err)
		return 125
	}
	err := execContainerCommand(args[2:], os.Environ())
	fmt.Fprintf(os.Stderr, "exec %q: %v\n", args[2], err)
	if errors.Is(err, unix.ENOENT) || errors.Is(err, unix.ENOTDIR) {
		return 127
	}
	return 126
}

func installConsoleIO(socket, mode string) error {
	local := [3]int{-1, -1, -1}
	var remote []int
	switch mode {
	case "tty":
		master, slave, err := openContainerPTY()
		if err != nil {
			return err
		}
		defer unix.Close(slave)
		defer unix.Close(master)
		local = [3]int{slave, slave, slave}
		remote = []int{master}
	case "pipes", "output":
		var pipes [3][2]int
		first := 1
		if mode == "pipes" {
			first = 0
		}
		for i := first; i < len(pipes); i++ {
			if err := unix.Pipe2(pipes[i][:], unix.O_CLOEXEC); err != nil {
				return err
			}
			defer unix.Close(pipes[i][0])
			defer unix.Close(pipes[i][1])
		}
		local[1], local[2] = pipes[1][1], pipes[2][1]
		remote = []int{pipes[1][0], pipes[2][0]}
		if mode == "pipes" {
			local[0] = pipes[0][0]
			remote = append(remote, pipes[0][1])
		}
	default:
		return errors.New("invalid console mode")
	}

	dialer := net.Dialer{Timeout: dockerPID1Startup}
	stream, err := dialer.Dial("unixpacket", socket)
	if err != nil {
		return err
	}
	conn := stream.(*net.UnixConn)
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(dockerPID1Startup)); err != nil {
		return err
	}
	rights := unix.UnixRights(remote...)
	if n, sent, err := conn.WriteMsgUnix([]byte{1}, rights, nil); err != nil || n != 1 || sent != len(rights) {
		return fmt.Errorf("send console file descriptors (%d/%d): %w", n, sent, err)
	}
	var ack [1]byte
	if n, err := conn.Read(ack[:]); n != 1 || err != nil || ack[0] != 1 {
		return fmt.Errorf("console was not accepted: %v", err)
	}
	for i, fd := range local {
		if fd < 0 {
			continue
		}
		if err := unix.Dup3(fd, i, 0); err != nil {
			return err
		}
	}
	return nil
}

func openContainerPTY() (master, slave int, err error) {
	master, err = unix.Open("/dev/ptmx", unix.O_RDWR|unix.O_NOCTTY|unix.O_CLOEXEC, 0)
	if err != nil {
		return -1, -1, err
	}
	defer func(fd int) {
		if err != nil {
			_ = unix.Close(fd)
		}
	}(master)
	if err := unix.IoctlSetPointerInt(master, unix.TIOCSPTLCK, 0); err != nil {
		return -1, -1, err
	}
	fd, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(master), unix.TIOCGPTPEER, uintptr(unix.O_RDWR|unix.O_NOCTTY|unix.O_CLOEXEC))
	if errno != 0 {
		return -1, -1, errno
	}
	slave = int(fd)
	// crun sets up a private session before executing the init process.
	if err := unix.IoctlSetInt(slave, unix.TIOCSCTTY, 0); err != nil {
		_ = unix.Close(slave)
		return -1, -1, err
	}
	return master, slave, nil
}

func execContainerCommand(argv, env []string) error {
	name := argv[0]
	if strings.Contains(name, "/") {
		return unix.Exec(name, argv, env)
	}
	path, ok := os.LookupEnv("PATH")
	if !ok {
		path = "/bin:/usr/bin"
	}
	resolved, err := findContainerExecutable(path, name)
	if err != nil {
		return err
	}
	return unix.Exec(resolved, argv, env)
}

func findContainerExecutable(path, name string) (string, error) {
	var last error = unix.ENOENT
	for _, base := range strings.Split(path, ":") {
		if base == "" {
			base = "."
		}
		// Preserve how the kernel resolves symlinks before parent components.
		candidate := base + "/" + name
		info, err := os.Stat(candidate)
		if err == nil {
			if info.Mode().IsRegular() {
				err = unix.Faccessat(unix.AT_FDCWD, candidate, unix.X_OK, unix.AT_EACCESS)
				if err == nil {
					return candidate, nil
				}
			} else {
				err = unix.EACCES
			}
		}
		if !errors.Is(err, unix.ENOENT) && !errors.Is(err, unix.ENOTDIR) {
			last = err
		}
	}
	return "", last
}
