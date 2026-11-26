//go:build linux

// Minimal Linux arm64 PID-1 bootstrap & AF_VSOCK<->Unix socket supervisor for
// booting Micropod's unmodified Alpine 3.23 CI worker directly on micropod-vmm.
// Stage 1 (in initramfs): mounts /dev/vda ext4, copies itself to /newroot/run/mp-hvf-init,
// performs real switch_root so crun's pivot_root works cleanly.
// Stage 2 (on real ext4 root): mounts /proc, /sys, /dev, /run, /tmp, cgroup2,
// virtiofs shares (oci-tools -> /opt/micropod-oci, workspace -> host path,
// mp-config -> /run/micropod/host-config), configures lo, eth0 and eth1 over
// rtnetlink (netconf_linux.go), starts AF_VSOCK <-> Unix bridges for
// docker.sock (2375), oci.sock (2376), buildkit.sock (2377), ports.sock
// (2378), and supervises /opt/micropod-oci/runner/start.sh.
//
// Boot arguments: mp.workspace / mp.workspace_b64 (share mount point),
// mp.config=1 (mount the host config share, tag mp-config, read-only at
// /run/micropod/host-config; without it nothing is mounted and the engine uses
// its built-in policy defaults), mp.mtu (published link MTU; default: the
// device's), mp.published_path (macvlan | bridge | default), mp.worker /
// mp.instance (engine identity).
//
// Stopping: a host POWEROFF (or SIGTERM to PID 1) stops the engine within the
// host's SHUTDOWN_BUDGET, remounts ext4 read-only and powers off (PSCI
// SYSTEM_OFF). If the engine exits on its own, or init cannot start, the guest
// prints "MICROPOD_VMM_GUEST_STATUS <kind> <detail>", flushes the disk and
// resets (PSCI SYSTEM_RESET), so micropod-vmm exits 4 rather than 0.
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

// statfs(2) f_flags bits (Linux ST_RDONLY, ST_NOSUID, ST_NODEV, ST_NOEXEC).
const (
	stRdonly = 0x1
	stNosuid = 0x2
	stNodev  = 0x4
	stNoexec = 0x8
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

// budget is the shutdown time granted by the host (SHUTDOWN_BUDGET), or the default.
var budget shutdownBudget

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
		_ = processCtrlStream(fdRW{fd: vfd}, ctrlHandlers{
			clock: setRealtimeClock,
			poweroff: func() {
				select {
				case poweroffCh <- struct{}{}:
				default:
				}
			},
			budget: budget.Store,
		})
		_ = syscall.Close(vfd)
	}
}

// reportGuestFailure prints the console marker micropod-vmm turns into a
// failure exit code, on a line of its own.
func reportGuestFailure(kind, detail string) {
	fmt.Fprintf(os.Stderr, "[mp-hvf-init] %s: %s\n", kind, detail)
	fmt.Printf("\n%s\n", guestFailureLine(kind, detail))
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

// gracefulStop ends the guest within `total`: stop every remaining daemon
// (containerd, job engine, service) so BoltDB and container state flush, sync,
// and remount ext4 read-only so the next boot needs no journal recovery. An
// orderly stop then powers off (PSCI SYSTEM_OFF); a failure stop resets (PSCI
// SYSTEM_RESET) so the host never mistakes it for a requested poweroff.
func gracefulStop(workspace string, total time.Duration, orderly bool) {
	// sync(2) and the unmounts can block behind a stalled virtio-fs request
	// (a host volume that stopped answering). Never let that keep the VM up:
	// the host is not waiting on a failure stop, so nothing else would end it.
	// A host-requested stop is timed by the host, which reports a forced stop
	// at its own deadline (budget + 1s); this one fires after it.
	deadline := total
	if orderly {
		deadline += orderlyStopSlack
	}
	armStopDeadline(deadline, orderly)
	phases := splitShutdownBudget(total)
	_ = syscall.Kill(-1, syscall.SIGTERM)
	if !reapChildrenUntil(time.Now().Add(phases.term)) {
		_ = syscall.Kill(-1, syscall.SIGKILL)
		_ = reapChildrenUntil(time.Now().Add(phases.kill))
	}
	syscall.Sync()
	if workspace != "" {
		_ = syscall.Unmount(workspace, syscall.MNT_DETACH)
	}
	_ = syscall.Unmount(hostConfigMount, syscall.MNT_DETACH)
	_ = syscall.Unmount("/opt/micropod-oci", syscall.MNT_DETACH)
	if err := syscall.Mount("", "/", "", syscall.MS_REMOUNT|syscall.MS_RDONLY, ""); err != nil {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] remount / read-only: %v (next boot replays the journal)\n", err)
	}
	syscall.Sync()
	if orderly {
		_ = syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF)
	}
	_ = syscall.Reboot(syscall.LINUX_REBOOT_CMD_RESTART)
}

// armStopDeadline makes the final PSCI call itself if the stop path has not
// reached it in time. A Go timer runs on another thread, so it fires while the
// main goroutine is stuck in sync(2).
func armStopDeadline(after time.Duration, orderly bool) *time.Timer {
	return time.AfterFunc(after, func() {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] stop did not finish within %v; stopping the VM now\n", after)
		if orderly {
			_ = syscall.Reboot(syscall.LINUX_REBOOT_CMD_POWER_OFF)
		}
		_ = syscall.Reboot(syscall.LINUX_REBOOT_CMD_RESTART)
	})
}

const (
	// orderlyStopSlack puts an orderly stop's own deadline past the host's.
	orderlyStopSlack = 2 * time.Second
	// fatalResetDeadline bounds the flush fatalReset attempts before resetting.
	fatalResetDeadline = 5 * time.Second
)

// fatalReset reports an init failure, flushes what it can and resets the VM.
// PID 1 must never simply exit: the kernel would panic instead.
func fatalReset(err error) {
	reportGuestFailure("init-failed", err.Error())
	armStopDeadline(fatalResetDeadline, false)
	syscall.Sync()
	_ = syscall.Unmount(hostConfigMount, syscall.MNT_DETACH)
	_ = syscall.Mount("", "/", "", syscall.MS_REMOUNT|syscall.MS_RDONLY, "")
	syscall.Sync()
	_ = syscall.Reboot(syscall.LINUX_REBOOT_CMD_RESTART)
	os.Exit(1)
}

func mustMount(src, dst, fstype string, flags uintptr, data string) {
	_ = os.MkdirAll(dst, 0755)
	if err := syscall.Mount(src, dst, fstype, flags, data); err != nil {
		if err != syscall.EBUSY {
			fmt.Fprintf(os.Stderr, "[mp-hvf-init] mount %s -> %s (%s): %v\n", src, dst, fstype, err)
		}
	}
}

// mountHostConfig mounts the host config share read-only at
// /run/micropod/host-config, before start.sh so the engine's mount namespace
// has it. The engine falls back to its built-in policy without it, so a
// failure is reported (console marker included) but the boot goes on.
func mountHostConfig(params map[string]string) {
	requested, err := hostConfigRequested(params)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] %v; no host config share\n", err)
	}
	if !requested {
		return
	}
	if err := os.MkdirAll(hostConfigMount, 0755); err != nil {
		reportGuestFailure("config-share", fmt.Sprintf("mkdir %s: %v", hostConfigMount, err))
		return
	}
	flags := uintptr(syscall.MS_RDONLY | syscall.MS_NOSUID | syscall.MS_NODEV | syscall.MS_NOEXEC)
	if err := syscall.Mount(hostConfigTag, hostConfigMount, "virtiofs", flags, ""); err != nil {
		reportGuestFailure("config-share",
			fmt.Sprintf("mount %s at %s: %v; the engine uses its built-in policy", hostConfigTag, hostConfigMount, err))
		return
	}
	var st syscall.Statfs_t
	if err := syscall.Statfs(hostConfigMount, &st); err == nil {
		fmt.Printf("[mp-hvf-init] host config: %s ro=%t nosuid=%t nodev=%t noexec=%t\n", hostConfigMount,
			st.Flags&stRdonly != 0, st.Flags&stNosuid != 0, st.Flags&stNodev != 0, st.Flags&stNoexec != 0)
	}
}

func stage1SwitchRoot() {
	mustMount("proc", "/proc", "proc", 0, "")
	if err := initializeBootClock(); err != nil {
		fatalReset(fmt.Errorf("boot clock: %w", err))
	}
	mustMount("sysfs", "/sys", "sysfs", 0, "")
	mustMount("devtmpfs", "/dev", "devtmpfs", 0, "")

	_ = os.MkdirAll("/newroot", 0755)
	for i := range 50 {
		if err := syscall.Mount("/dev/vda", "/newroot", "ext4", syscall.MS_NOATIME, "max_batch_time=15000"); err == nil {
			break
		} else if i == 49 {
			fatalReset(fmt.Errorf("mount /dev/vda: %w", err))
		}
		time.Sleep(10 * time.Millisecond)
	}
	mustMount("tmpfs", "/newroot/run", "tmpfs", syscall.MS_NOSUID|syscall.MS_NODEV, "mode=0755")
	// Copy ourselves into /newroot/run/mp-hvf-init before switch_root
	selfBytes, err := os.ReadFile("/init")
	if err != nil {
		fatalReset(fmt.Errorf("read /init: %w", err))
	}
	if err := os.WriteFile("/newroot/run/mp-hvf-init", selfBytes, 0755); err != nil {
		fatalReset(fmt.Errorf("write /newroot/run/mp-hvf-init: %w", err))
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
		fatalReset(fmt.Errorf("chdir /newroot: %w", err))
	}
	if err := syscall.Mount(".", "/", "", syscall.MS_MOVE, ""); err != nil {
		fatalReset(fmt.Errorf("MS_MOVE /: %w", err))
	}
	if err := syscall.Chroot("."); err != nil {
		fatalReset(fmt.Errorf("chroot .: %w", err))
	}
	_ = syscall.Chdir("/")
	if err := syscall.Exec("/run/mp-hvf-init", []string{"/run/mp-hvf-init", "--stage2"}, os.Environ()); err != nil {
		fatalReset(fmt.Errorf("exec stage2: %w", err))
	}
}

func stage2Fail(err error) {
	fatalReset(err)
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
	_ = syscall.Sethostname([]byte("micropod-hvf"))

	// Mount Virtio-FS shares
	mustMount("oci-tools", "/opt/micropod-oci", "virtiofs", syscall.MS_RDONLY, "")
	if workspace != "" {
		if err := prepareWorkspaceMount(workspace); err != nil {
			stage2Fail(fmt.Errorf("prepare workspace mount %q: %w", workspace, err))
		}
		// nosuid,nodev: the Mac's files are not the guest's to elevate with. The
		// VMM also never keeps or reports set-id bits on them, because container
		// runtimes remount bind mounts without nosuid.
		if err := syscall.Mount("workspace", workspace, "virtiofs", syscall.MS_NOSUID|syscall.MS_NODEV, ""); err != nil {
			stage2Fail(fmt.Errorf("mount workspace %q: %w", workspace, err))
		}
		var st syscall.Statfs_t
		if err := syscall.Statfs(workspace, &st); err == nil {
			fmt.Printf("[mp-hvf-init] workspace: %s nosuid=%t nodev=%t\n",
				workspace, st.Flags&stNosuid != 0, st.Flags&stNodev != 0)
		}
	}
	mountHostConfig(params)

	// Bring up loopback, eth0 (egress 10.42.0.2/24 via 10.42.0.1) and, with
	// --published-net, eth1 (published link 10.43.0.2/24, permanent gateway
	// neighbour) over rtnetlink; the image's BusyBox `ip` lacks `replace`.
	publishedMTU := setupGuestNetwork(params["mp.mtu"])

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
	}
	if publishedMTU > 0 {
		// Engines with a dedicated published link serve ports on eth1; older ones
		// ignore these and keep their relay on eth0 (the VMM handles both).
		env = append(env,
			"MICROPOD_CI_PORT_THROUGHPUT=1",
			"MICROPOD_CI_PUBLISH_IPV4=10.43.0.2",
			"MICROPOD_CI_PUBLISH_GATEWAY=10.43.0.1",
			"MICROPOD_CI_PUBLISHED_MTU="+strconv.Itoa(publishedMTU),
		)
		if path, err := publishedPathEnv(params["mp.published_path"]); err != nil {
			fmt.Fprintf(os.Stderr, "[mp-hvf-init] %v; using the default\n", err)
			env = append(env, "MICROPOD_CI_PUBLISHED_PATH=macvlan")
		} else if path != "" {
			env = append(env, "MICROPOD_CI_PUBLISHED_PATH="+path)
		}
	}
	if workspace != "" {
		env = append(env, "MICROPOD_ENGINE_WORKSPACE="+workspace)
	}

	fmt.Println("MICROPOD_VMM_INIT_READY")
	cmd := exec.Command("/run/mp-hvf-init", "--stage3")
	cmd.Env = env
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		reportGuestFailure("engine-exited", fmt.Sprintf("start failed: %v", err))
		gracefulStop(workspace, budget.Load(), false)
		os.Exit(1)
	}

	// PID 1 reaps every orphan with wait4(-1), so it also collects start.sh: a
	// separate cmd.Wait would race it and could lose the engine's exit status.
	enginePID := cmd.Process.Pid
	done := make(chan syscall.WaitStatus, 1)
	reap := func() {
		for {
			var ws syscall.WaitStatus
			pid, err := syscall.Wait4(-1, &ws, syscall.WNOHANG, nil)
			if pid <= 0 || err != nil {
				return
			}
			if pid == enginePID {
				done <- ws
			}
		}
	}
	reap() // start.sh may already have exited before SIGCHLD was observed

	var shutdownTimer *time.Timer
	var shutdownTimeout <-chan time.Time
	var stopBudget time.Duration
	triggerShutdown := func() {
		if shutdownTimer == nil {
			_ = cmd.Process.Signal(syscall.SIGTERM)
			stopBudget = budget.Load()
			shutdownTimer = time.NewTimer(engineStopGrace(stopBudget))
			shutdownTimeout = shutdownTimer.C
		}
	}

	for {
		select {
		case ws := <-done:
			if shutdownTimer != nil {
				// The host asked for this stop: power off in an orderly way.
				shutdownTimer.Stop()
				fmt.Fprintf(os.Stderr, "[mp-hvf-init] start.sh stopped: %s\n", waitDescription(ws))
				gracefulStop(workspace, stopBudget, true)
				return
			}
			// The engine died on its own. Keep the disk clean, then tell the host
			// this was a failure rather than a requested poweroff.
			reportGuestFailure("engine-exited", waitDescription(ws))
			gracefulStop(workspace, budget.Load(), false)
			return
		case <-poweroffCh:
			triggerShutdown()
		case <-shutdownTimeout:
			fmt.Fprintln(os.Stderr, "[mp-hvf-init] engine stop grace elapsed; stopping remaining processes")
			gracefulStop(workspace, stopBudget, true)
			return
		case sig := <-sigCh:
			if sig == syscall.SIGCHLD {
				reap()
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
