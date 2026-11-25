//go:build linux

// Minimal Linux arm64 PID-1 bootstrap & AF_VSOCK<->Unix socket supervisor for
// booting Micropod's unmodified Alpine 3.23 CI worker directly on micropod-vmm.
// Stage 1 (in initramfs): mounts /dev/vda ext4, copies itself to /newroot/run/mp-hvf-init,
// performs real switch_root so crun's pivot_root works cleanly.
// Stage 2 (on real ext4 root): mounts /proc, /sys, /dev, /run, /tmp, cgroup2,
// virtiofs shares (oci-tools -> /opt/micropod-oci, workspace -> host path),
// configures eth0 + eth1 (MTU 9000), starts AF_VSOCK <-> Unix bridges for
// docker.sock (2375), oci.sock (2376), buildkit.sock (2377), ports.sock (2378),
// and supervises /opt/micropod-oci/runner/start.sh.
package main

import (
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const (
	afVsock       = 40
	vmaddrCidAny  = 0xffffffff
	vmaddrCidHost = 2
	portDocker    = 2375
	portOCI       = 2376
	portBuildkit  = 2377
	portBroker    = 2378
	portCtrl      = 2379
)

type sockaddrVM struct {
	Family    uint16
	Reserved1 uint16
	Port      uint32
	CID       uint32
	Flags     uint8
	Zero      [3]byte
}

func vsockListen(port uint32) (int, error) {
	fd, err := syscall.Socket(afVsock, syscall.SOCK_STREAM|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return -1, err
	}
	sa := sockaddrVM{Family: afVsock, Port: port, CID: vmaddrCidAny}
	_, _, errno := syscall.Syscall(syscall.SYS_BIND, uintptr(fd), uintptr(unsafe.Pointer(&sa)), unsafe.Sizeof(sa))
	if errno != 0 {
		syscall.Close(fd)
		return -1, errno
	}
	if err := syscall.Listen(fd, 128); err != nil {
		syscall.Close(fd)
		return -1, err
	}
	return fd, nil
}

func vsockAccept(lfd int) (int, error) {
	var sa sockaddrVM
	sz := uint32(unsafe.Sizeof(sa))
	r, _, errno := syscall.Syscall6(syscall.SYS_ACCEPT4, uintptr(lfd), uintptr(unsafe.Pointer(&sa)), uintptr(unsafe.Pointer(&sz)), syscall.SOCK_CLOEXEC, 0, 0)
	if errno != 0 {
		return -1, errno
	}
	return int(r), nil
}

func vsockDialHost(port uint32) (int, error) {
	fd, err := syscall.Socket(afVsock, syscall.SOCK_STREAM|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return -1, err
	}
	sa := sockaddrVM{Family: afVsock, Port: port, CID: vmaddrCidHost}
	_, _, errno := syscall.Syscall(syscall.SYS_CONNECT, uintptr(fd), uintptr(unsafe.Pointer(&sa)), unsafe.Sizeof(sa))
	if errno != 0 {
		syscall.Close(fd)
		return -1, errno
	}
	return fd, nil
}

type fdRW struct{ fd int }

func (f fdRW) Read(p []byte) (int, error) {
	for {
		n, err := syscall.Read(f.fd, p)
		if err == syscall.EINTR {
			continue
		}
		if n == 0 && err == nil {
			return 0, io.EOF
		}
		return n, err
	}
}

func (f fdRW) Write(p []byte) (int, error) {
	total := 0
	for total < len(p) {
		n, err := syscall.Write(f.fd, p[total:])
		if err == syscall.EINTR {
			continue
		}
		if err != nil {
			return total, err
		}
		total += n
	}
	return total, nil
}

func bridgeVsockToUnix(guestPort uint32, unixPath string) {
	lfd, err := vsockListen(guestPort)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] vsock listen %d failed: %v\n", guestPort, err)
		return
	}
	for {
		cfd, err := vsockAccept(lfd)
		if err != nil {
			if err == syscall.EINTR {
				continue
			}
			time.Sleep(10 * time.Millisecond)
			continue
		}
		go func(vsockFD int) {
			defer syscall.Close(vsockFD)
			var uconn *net.UnixConn
			for range 100 {
				c, e := net.DialUnix("unix", nil, &net.UnixAddr{Name: unixPath, Net: "unix"})
				if e == nil {
					uconn = c
					break
				}
				time.Sleep(25 * time.Millisecond)
			}
			if uconn == nil {
				return
			}
			defer uconn.Close()
			vs := fdRW{fd: vsockFD}
			done := make(chan struct{})
			go func() {
				_, _ = io.Copy(uconn, vs)
				_ = uconn.CloseWrite()
				close(done)
			}()
			_, _ = io.Copy(vs, uconn)
			_ = syscall.Shutdown(vsockFD, syscall.SHUT_WR)
			<-done
		}(cfd)
	}
}

func bridgeUnixToVsockHost(unixPath string, hostPort uint32) {
	_ = os.MkdirAll(filepath.Dir(unixPath), 0700)
	_ = os.Remove(unixPath)
	ln, err := net.ListenUnix("unix", &net.UnixAddr{Name: unixPath, Net: "unix"})
	if err != nil {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] unix listen %s failed: %v\n", unixPath, err)
		return
	}
	_ = os.Chmod(unixPath, 0600)
	for {
		uconn, err := ln.AcceptUnix()
		if err != nil {
			continue
		}
		go func(c *net.UnixConn) {
			defer c.Close()
			vfd, err := vsockDialHost(hostPort)
			if err != nil {
				return
			}
			defer syscall.Close(vfd)
			vs := fdRW{fd: vfd}
			done := make(chan struct{})
			go func() {
				_, _ = io.Copy(vs, c)
				_ = syscall.Shutdown(vfd, syscall.SHUT_WR)
				close(done)
			}()
			_, _ = io.Copy(c, vs)
			_ = c.CloseWrite()
			<-done
		}(uconn)
	}
}

func runHostControlLoop(poweroffCh chan<- struct{}) {
	backoff := 10 * time.Millisecond
	for {
		vfd, err := vsockDialHost(portCtrl)
		if err != nil {
			time.Sleep(backoff)
			if backoff < 2*time.Second {
				backoff *= 2
			}
			continue
		}
		backoff = 10 * time.Millisecond
		_ = processCtrlStream(
			fdRW{fd: vfd},
			func(unixNs int64) error {
				return setRealtimeClock(unixNs)
			},
			func() {
				select {
				case poweroffCh <- struct{}{}:
				default:
				}
			},
		)
		_ = syscall.Close(vfd)
	}
}

func reapChildrenUntil(deadline time.Time) bool {
	for {
		for {
			var ws syscall.WaitStatus
			pid, err := syscall.Wait4(-1, &ws, syscall.WNOHANG, nil)
			if err == syscall.ECHILD {
				return true
			}
			if pid <= 0 || err != nil {
				break
			}
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func gracefulPoweroff(workspace string) {
	// Stop all remaining guest daemons (containerd, job engine, service) so BoltDB and
	// container state flush cleanly before ext4 sync and PSCI_SYSTEM_OFF.
	_ = syscall.Kill(-1, syscall.SIGTERM)
	if !reapChildrenUntil(time.Now().Add(800 * time.Millisecond)) {
		_ = syscall.Kill(-1, syscall.SIGKILL)
		_ = reapChildrenUntil(time.Now().Add(200 * time.Millisecond))
	}
	syscall.Sync()
	if workspace != "" {
		_ = syscall.Unmount(workspace, syscall.MNT_DETACH)
	}
	_ = syscall.Unmount("/opt/micropod-oci", syscall.MNT_DETACH)
	_ = syscall.Mount("", "/", "", syscall.MS_REMOUNT|syscall.MS_RDONLY, "")
	syscall.Sync()
	_ = syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF)
}

func cmdlineParams(fields []string) map[string]string {
	out := map[string]string{}
	for _, f := range fields {
		if k, v, ok := strings.Cut(f, "="); ok {
			out[k] = v
		}
	}
	return out
}

func mustMount(src, dst, fstype string, flags uintptr, data string) {
	_ = os.MkdirAll(dst, 0755)
	if err := syscall.Mount(src, dst, fstype, flags, data); err != nil {
		if err != syscall.EBUSY {
			fmt.Fprintf(os.Stderr, "[mp-hvf-init] mount %s -> %s (%s): %v\n", src, dst, fstype, err)
		}
	}
}

func stage1SwitchRoot() {
	mustMount("proc", "/proc", "proc", 0, "")
	if err := initializeBootClock(); err != nil {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] FATAL: boot clock: %v\n", err)
		_ = syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF)
		os.Exit(1)
	}
	mustMount("sysfs", "/sys", "sysfs", 0, "")
	mustMount("devtmpfs", "/dev", "devtmpfs", 0, "")

	_ = os.MkdirAll("/newroot", 0755)
	for i := range 50 {
		if err := syscall.Mount("/dev/vda", "/newroot", "ext4", syscall.MS_NOATIME, "max_batch_time=15000"); err == nil {
			break
		} else if i == 49 {
			fmt.Fprintf(os.Stderr, "[mp-hvf-init] FATAL: failed mounting /dev/vda: %v\n", err)
			_ = syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF)
			os.Exit(1)
		}
		time.Sleep(10 * time.Millisecond)
	}
	mustMount("tmpfs", "/newroot/run", "tmpfs", syscall.MS_NOSUID|syscall.MS_NODEV, "mode=0755")
	// Copy ourselves into /newroot/run/mp-hvf-init before switch_root
	selfBytes, err := os.ReadFile("/init")
	if err != nil {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] read /init: %v\n", err)
		os.Exit(1)
	}
	if err := os.WriteFile("/newroot/run/mp-hvf-init", selfBytes, 0755); err != nil {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] write /newroot/run/mp-hvf-init: %v\n", err)
		os.Exit(1)
	}
	// Move virtual filesystems onto /newroot
	_ = os.MkdirAll("/newroot/proc", 0755)
	_ = os.MkdirAll("/newroot/sys", 0755)
	_ = os.MkdirAll("/newroot/dev", 0755)
	_ = syscall.Mount("/proc", "/newroot/proc", "", syscall.MS_MOVE, "")
	_ = syscall.Mount("/sys", "/newroot/sys", "", syscall.MS_MOVE, "")
	_ = syscall.Mount("/dev", "/newroot/dev", "", syscall.MS_MOVE, "")

	// Standard Linux switch_root so / is ext4 (required for crun pivot_root!)
	if err := syscall.Chdir("/newroot"); err != nil {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] chdir /newroot: %v\n", err)
		os.Exit(1)
	}
	if err := syscall.Mount(".", "/", "", syscall.MS_MOVE, ""); err != nil {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] MS_MOVE /: %v\n", err)
		os.Exit(1)
	}
	if err := syscall.Chroot("."); err != nil {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] chroot .: %v\n", err)
		os.Exit(1)
	}
	_ = syscall.Chdir("/")
	if err := syscall.Exec("/run/mp-hvf-init", []string{"/run/mp-hvf-init", "--stage2"}, os.Environ()); err != nil {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] exec stage2: %v\n", err)
		os.Exit(1)
	}
}

func runCmd(name string, args ...string) {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	_ = cmd.Run()
}

func stage2Fail(err error) {
	fmt.Fprintf(os.Stderr, "[mp-hvf-init] FATAL: %v\n", err)
	_ = syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF)
	os.Exit(1)
}

func stage2Supervise() {
	cmdline, err := os.ReadFile("/proc/cmdline")
	if err != nil {
		stage2Fail(fmt.Errorf("read /proc/cmdline: %w", err))
	}
	fields := strings.Fields(string(cmdline))
	workspace, err := parseWorkspace(fields)
	if err != nil {
		stage2Fail(err)
	}
	mustMount("tmpfs", "/tmp", "tmpfs", syscall.MS_NOSUID|syscall.MS_NODEV, "mode=1777")
	mustMount("devpts", "/dev/pts", "devpts", 0, "gid=5,mode=620")
	mustMount("tmpfs", "/dev/shm", "tmpfs", syscall.MS_NOSUID|syscall.MS_NODEV, "mode=1777")
	mustMount("cgroup2", "/sys/fs/cgroup", "cgroup2", syscall.MS_NOSUID|syscall.MS_NODEV|syscall.MS_NOEXEC, "")

	params := cmdlineParams(fields)
	workerID := params["mp.worker"]
	if workerID == "" {
		workerID = "00000000-0000-4000-8000-000000000001"
	}
	instanceID := params["mp.instance"]
	if instanceID == "" {
		instanceID = "00000000-0000-4000-8000-000000000002"
	}
	mtu := params["mp.mtu"]
	if mtu == "" {
		mtu = "9000"
	}

	_ = syscall.Sethostname([]byte("micropod-hvf"))

	// Mount Virtio-FS shares
	mustMount("oci-tools", "/opt/micropod-oci", "virtiofs", syscall.MS_RDONLY, "")
	if workspace != "" {
		if err := prepareWorkspaceMount(workspace); err != nil {
			stage2Fail(fmt.Errorf("prepare workspace mount %q: %w", workspace, err))
		}
		if err := syscall.Mount("workspace", workspace, "virtiofs", 0, ""); err != nil {
			stage2Fail(fmt.Errorf("mount workspace %q: %w", workspace, err))
		}
	}

	// Bring up loopback, eth0 (primary 10.42.0.2/24), and eth1 (published 10.43.0.2/24 MTU 9000)
	runCmd("/sbin/ip", "link", "set", "lo", "up")
	runCmd("/sbin/ip", "addr", "replace", "127.0.0.1/8", "dev", "lo")
	runCmd("/sbin/ip", "link", "set", "eth0", "up")
	runCmd("/sbin/ip", "addr", "replace", "10.42.0.2/24", "dev", "eth0")
	runCmd("/sbin/ip", "route", "replace", "default", "via", "10.42.0.1", "dev", "eth0")
	if _, err := os.Stat("/sys/class/net/eth1"); err == nil {
		runCmd("/sbin/ip", "link", "set", "eth1", "mtu", mtu, "up")
		runCmd("/sbin/ip", "addr", "replace", "10.43.0.2/24", "dev", "eth1")
		runCmd("/sbin/ip", "neigh", "replace", "10.43.0.1", "lladdr", "52:54:00:ab:cd:02", "nud", "permanent", "dev", "eth1")
	}

	// Delegate cgroup2 root: move PID 1 to /sys/fs/cgroup/init, enable controllers on root,
	// and create /sys/fs/cgroup/worker so start.sh runs in a clean cgroup namespace (no kthreads).
	_ = os.MkdirAll("/sys/fs/cgroup/init", 0755)
	_ = os.WriteFile("/sys/fs/cgroup/init/cgroup.procs", []byte("1\n"), 0644)
	for _, ctrl := range []string{"+cpu", "+memory", "+pids", "+cpuset"} {
		_ = os.WriteFile("/sys/fs/cgroup/cgroup.subtree_control", []byte(ctrl+"\n"), 0644)
	}
	_ = os.MkdirAll("/sys/fs/cgroup/worker", 0755)

	// Minimal /etc/resolv.conf & /etc/hosts for job engine DNS startup
	_ = os.WriteFile("/etc/resolv.conf", []byte("nameserver 10.42.0.1\n"), 0644)
	_ = os.WriteFile("/etc/hosts", []byte("127.0.0.1 localhost micropod-hvf\n"), 0644)

	// Start AF_VSOCK <-> Unix bridges and host control channel BEFORE start.sh launches job engine!
	poweroffCh := make(chan struct{}, 1)
	go runHostControlLoop(poweroffCh)
	go bridgeUnixToVsockHost("/var/lib/micropod/ports.sock", portBroker)
	go bridgeVsockToUnix(portDocker, "/var/lib/micropod/docker.sock")
	go bridgeVsockToUnix(portOCI, "/var/lib/micropod/oci.sock")
	go bridgeVsockToUnix(portBuildkit, "/var/lib/micropod/buildkit.sock")

	// Zombie reaper
	sigCh := make(chan os.Signal, 8)
	signal.Notify(sigCh, syscall.SIGCHLD, syscall.SIGTERM, syscall.SIGINT)

	env := []string{
		"PATH=/opt/micropod-oci/runner/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
		"HOME=/root",
		"MICROPOD_CI_WORKER_ID=" + workerID,
		"MICROPOD_CI_INSTANCE=" + instanceID,
		"MICROPOD_NATIVE_OCI=1",
		"MICROPOD_ENGINE_API=1",
		"MICROPOD_CI_PUBLISHED_PATH=macvlan",
		"MICROPOD_CI_PORT_THROUGHPUT=1",
		"MICROPOD_CI_PUBLISH_IPV4=10.43.0.2",
		"MICROPOD_CI_PUBLISH_GATEWAY=10.43.0.1",
	}
	if workspace != "" {
		env = append(env, "MICROPOD_ENGINE_WORKSPACE="+workspace)
	}
	if _, err := strconv.Atoi(mtu); err == nil {
		env = append(env, "MICROPOD_CI_PUBLISHED_MTU="+mtu)
	}

	fmt.Println("MICROPOD_VMM_INIT_READY")
	cmd := exec.Command("/run/mp-hvf-init", "--stage3")
	cmd.Env = env
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] start.sh failed: %v\n", err)
		gracefulPoweroff(workspace)
		os.Exit(1)
	}

	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()

	var shutdownTimer *time.Timer
	var shutdownTimeout <-chan time.Time
	triggerShutdown := func() {
		if shutdownTimer == nil {
			_ = cmd.Process.Signal(syscall.SIGTERM)
			shutdownTimer = time.NewTimer(1500 * time.Millisecond)
			shutdownTimeout = shutdownTimer.C
		}
	}

	for {
		select {
		case err := <-done:
			if shutdownTimer != nil {
				shutdownTimer.Stop()
			}
			fmt.Fprintf(os.Stderr, "[mp-hvf-init] start.sh exited: %v\n", err)
			gracefulPoweroff(workspace)
			return
		case <-poweroffCh:
			triggerShutdown()
		case <-shutdownTimeout:
			fmt.Fprintln(os.Stderr, "[mp-hvf-init] graceful shutdown timer elapsed; syncing and powering off")
			gracefulPoweroff(workspace)
			return
		case sig := <-sigCh:
			if sig == syscall.SIGCHLD {
				for {
					var ws syscall.WaitStatus
					pid, err := syscall.Wait4(-1, &ws, syscall.WNOHANG, nil)
					if pid <= 0 || err != nil {
						break
					}
				}
			} else {
				triggerShutdown()
			}
		}
	}
}

func stage3LaunchWorker() {
	// Move ourselves into /sys/fs/cgroup/worker, unshare cgroup + mount namespaces,
	// remount /sys/fs/cgroup rooted at /worker (zero kernel threads visible!), and exec start.sh.
	_ = os.WriteFile("/sys/fs/cgroup/worker/cgroup.procs", []byte(strconv.Itoa(os.Getpid())+"\n"), 0644)
	const cloneNewCgroup = 0x02000000
	if err := syscall.Unshare(cloneNewCgroup | syscall.CLONE_NEWNS); err == nil {
		_ = syscall.Mount("", "/", "", syscall.MS_REC|syscall.MS_SLAVE, "")
		_ = syscall.Unmount("/sys/fs/cgroup", syscall.MNT_DETACH)
		_ = syscall.Mount("cgroup2", "/sys/fs/cgroup", "cgroup2", syscall.MS_NOSUID|syscall.MS_NODEV|syscall.MS_NOEXEC, "")
	}
	if err := syscall.Exec("/bin/sh", []string{"/bin/sh", "/opt/micropod-oci/runner/start.sh"}, os.Environ()); err != nil {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] exec start.sh: %v\n", err)
		os.Exit(1)
	}
}

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "--stage2":
			stage2Supervise()
			return
		case "--stage3":
			stage3LaunchWorker()
			return
		}
	}
	stage1SwitchRoot()
}
