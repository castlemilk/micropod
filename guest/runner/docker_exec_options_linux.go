package main

import (
	"encoding/json"
	"fmt"
	"path"
	"slices"
	"strings"
	"syscall"

	"google.golang.org/grpc/status"
)

const dockerExecRuntimeErrorPrefix = "OCI runtime exec failed: "

func validateDockerExecOverrides(env []string, workdir string) error {
	for _, entry := range env {
		name, _, _ := strings.Cut(entry, "=")
		if name == "" || strings.ContainsRune(entry, 0) {
			return fail(400, "invalid exec environment variable")
		}
	}
	if strings.ContainsRune(workdir, 0) {
		return fail(400, "invalid exec working directory")
	}
	return nil
}

func (e *dockerExec) applyProcessOverrides(process map[string]json.RawMessage) error {
	if e.workdir != "" {
		cwd, err := json.Marshal(e.workdir)
		if err != nil {
			return err
		}
		process["cwd"] = cwd
	}
	if !e.tty && len(e.env) == 0 {
		return nil
	}
	var inherited []string
	if b, ok := process["env"]; ok {
		if err := json.Unmarshal(b, &inherited); err != nil {
			return fmt.Errorf("read OCI process environment: %w", err)
		}
	}
	if e.tty && !slices.ContainsFunc(inherited, func(entry string) bool { return strings.HasPrefix(entry, "TERM=") }) {
		inherited = append(inherited, "TERM=xterm")
	}
	env := overlayDockerExecEnv(inherited, e.env)
	if len(env) == 0 && len(inherited) != 0 {
		// crun uses the init process environment when the exec env array is
		// empty. An unset entry keeps it from inheriting the removed values.
		name, _, _ := strings.Cut(inherited[0], "=")
		env = append(env, name)
	}
	value, err := json.Marshal(env)
	if err == nil {
		process["env"] = value
	}
	return err
}

func overlayDockerExecEnv(inherited, overrides []string) []string {
	env := make([]string, 0, len(inherited)+len(overrides))
	env = append(env, inherited...)
	positions := make(map[string]int, cap(env))
	for i, entry := range inherited {
		name, _, _ := strings.Cut(entry, "=")
		positions[name] = i
	}
	for _, entry := range overrides {
		name, _, hasValue := strings.Cut(entry, "=")
		i, exists := positions[name]
		// The CLI resolves bare names against its own environment. Docker
		// removes remaining bare names only when inherited by the exec.
		if !hasValue {
			if exists && i < len(inherited) {
				env[i] = ""
			}
			continue
		}
		if exists {
			env[i] = entry
		} else {
			positions[name] = len(env)
			env = append(env, entry)
		}
	}
	return slices.DeleteFunc(env, func(entry string) bool { return entry == "" })
}

type dockerExecWorkdirError struct {
	exit    int32
	message string
}

func (e dockerExecWorkdirError) Error() string { return e.message }

func (e *dockerExec) checkWorkingDir() error {
	if e.workdir != "" && !path.IsAbs(e.workdir) {
		return dockerExecWorkdirError{128, dockerExecRuntimeErrorPrefix + "exec failed: Cwd must be an absolute path"}
	}
	return nil
}

func (e *dockerExec) workdirStartError(err error) error {
	if e.workdir == "" {
		return err
	}
	_, detail, ok := strings.Cut(status.Convert(err).Message(), dockerExecRuntimeErrorPrefix)
	if !ok {
		return err
	}
	cause, ok := strings.CutPrefix(detail, "chdir to `"+e.workdir+"`: ")
	if !ok {
		cause, ok = strings.CutPrefix(detail, fmt.Sprintf("exec failed: unable to start container process: chdir to cwd (%q) set in config.json failed: ", e.workdir))
	}
	if !ok {
		return err
	}
	var exit int32 = 128
	switch cause := strings.ToLower(cause); {
	case strings.HasPrefix(cause, syscall.ENOENT.Error()), strings.HasPrefix(cause, syscall.ENOTDIR.Error()):
		exit = 127
	case strings.HasPrefix(cause, syscall.EACCES.Error()):
		exit = 126
	}
	return dockerExecWorkdirError{exit, dockerExecRuntimeErrorPrefix + detail}
}
