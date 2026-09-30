//go:build linux

// micropod-guest runs inside micropod sandbox VMs: file operations, path
// watches and the idle main process behind the SandboxService API. It is
// static and needs nothing from the image — no shell, no coreutils — so
// distroless images get the full API too. The host shares it read-only
// into each sandbox at /.micropod and runs it inside the container, so it
// sees the container's mounts and tmpfs, as the workload's user.
//
// Output is raw bytes (read) or JSON lines. A failure exits 1 with
// "micropod-guest: <ERRNO>: <message>" on stderr; the host maps the errno
// to an API error code.
package main

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"syscall"
)

func main() {
	if err := run(os.Args[1:], os.Stdin, os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "micropod-guest: %s: %v\n", errnoName(err), err)
		os.Exit(1)
	}
}

const usage = "usage: micropod-guest idle | read PATH [--max N] | write PATH [--append] [--mode OCTAL] [--parents] | " +
	"stat PATH | list DIR | mkdir PATH [--parents] | rm PATH [--recursive] | mv FROM TO | " +
	"cp FROM TO [--recursive] | chmod OCTAL PATH | watch PATH [--recursive]"

func run(args []string, stdin io.Reader, stdout io.Writer) error {
	if len(args) == 0 {
		return usageError(usage)
	}
	cmd, rest := args[0], args[1:]
	switch cmd {
	case "idle":
		return idle()
	case "read":
		return readFile(rest, stdout)
	case "write":
		return writeFile(rest, stdin)
	case "stat":
		return statPath(rest, stdout)
	case "list":
		return listDir(rest, stdout)
	case "mkdir":
		return makeDir(rest)
	case "rm":
		return remove(rest)
	case "mv":
		return rename(rest)
	case "cp":
		return copyPath(rest)
	case "chmod":
		return chmod(rest)
	case "watch":
		return watch(rest, stdout)
	default:
		return usageError("unknown command " + cmd + "; " + usage)
	}
}

// flags splits args into positionals and --flags; `valued` flags take the
// next argument.
type flags struct {
	pos []string
	set map[string]string
}

func parse(args []string, positionals int, valued ...string) (flags, error) {
	f := flags{set: map[string]string{}}
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if len(arg) > 2 && arg[:2] == "--" {
			takes := false
			for _, v := range valued {
				takes = takes || v == arg
			}
			if takes {
				if i+1 >= len(args) {
					return f, usageError(arg + " needs a value")
				}
				i++
				f.set[arg] = args[i]
			} else {
				f.set[arg] = ""
			}
			continue
		}
		f.pos = append(f.pos, arg)
	}
	if len(f.pos) != positionals {
		return f, usageError(fmt.Sprintf("want %d path argument(s), got %d; %s", positionals, len(f.pos), usage))
	}
	return f, nil
}

func (f flags) has(name string) bool {
	_, ok := f.set[name]
	return ok
}

type usageErr struct{ msg string }

func (e usageErr) Error() string { return e.msg }

func usageError(msg string) error { return usageErr{msg} }

var errnoNames = map[syscall.Errno]string{
	syscall.ENOENT: "ENOENT", syscall.EACCES: "EACCES", syscall.EPERM: "EPERM", syscall.EEXIST: "EEXIST",
	syscall.ENOTEMPTY: "ENOTEMPTY", syscall.EISDIR: "EISDIR", syscall.ENOTDIR: "ENOTDIR", syscall.EFBIG: "EFBIG",
	syscall.EROFS: "EROFS", syscall.EINVAL: "EINVAL", syscall.EXDEV: "EXDEV", syscall.ENOSPC: "ENOSPC",
	syscall.ELOOP: "ELOOP", syscall.ENAMETOOLONG: "ENAMETOOLONG", syscall.EBUSY: "EBUSY", syscall.EMFILE: "EMFILE",
	syscall.EDQUOT: "EDQUOT", syscall.ETXTBSY: "ETXTBSY",
}

// errnoName is the errno behind err ("EIO" when there is none; "EINVAL"
// for bad usage).
func errnoName(err error) string {
	var usage usageErr
	if errors.As(err, &usage) {
		return "EINVAL"
	}
	var errno syscall.Errno
	if errors.As(err, &errno) {
		if name, ok := errnoNames[errno]; ok {
			return name
		}
		return fmt.Sprintf("E%d", int(errno))
	}
	if errors.Is(err, fs.ErrNotExist) {
		return "ENOENT"
	}
	return "EIO"
}
