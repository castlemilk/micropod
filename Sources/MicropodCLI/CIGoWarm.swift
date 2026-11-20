import CryptoKit
import Foundation

extension CICommands {
    static func warmGoArguments(_ arguments: ArraySlice<String>) throws -> [String] {
        let usage = "ci warm-go requires --cache-scope NAME [--offline] [--trace-tools] SOURCE_IMAGE_ID [PACKAGE ...]"
        guard arguments.first == "--cache-scope", let scope = arguments.dropFirst().first else {
            throw UsageError(message: usage)
        }
        var rest = arguments.dropFirst(2)
        var offline = false
        var trace = false
        while let flag = rest.first, flag.hasPrefix("--") {
            switch flag {
            case "--offline" where !offline: offline = true
            case "--trace-tools" where !trace: trace = true
            default: throw UsageError(message: usage)
            }
            rest = rest.dropFirst()
        }
        guard let image = rest.first, image.wholeMatch(of: #/sha256:[0-9a-f]{64}/#) != nil else {
            throw UsageError(message: usage)
        }
        let packages = rest.count == 1 ? ["./..."] : Array(rest.dropFirst())
        guard packages.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.contains("\0") }) else {
            throw UsageError(message: usage)
        }
        // Only identical, overlapping requests can use another producer's completion.
        // Later requests recheck Go's own cache, including after eviction or a worker restart.
        let identity = ["go-warm-v2", scope, image, offline ? "offline" : "network"] + packages
        let key = SHA256.hash(data: Data(identity.joined(separator: "\0").utf8)).map { String(format: "%02x", $0) }
            .joined()
        let command =
            ["--pull=never", "--label", "io.micropod.ci.go-warm=" + key] + (offline ? ["--network", "none"] : [])
            + ["--entrypoint", "/bin/sh", image, "-ec", warmGoScript, "micropod-go-warm", key, trace ? "1" : "0"]
            + packages
        return try ["run", "--rm"] + runArguments(ArraySlice(["--cache", "go", "--cache-scope", scope] + command))
    }

    // The lock and success generation live with the Linux build volume. Docker and OCI
    // jobs can reuse its ordinary Go actions without participating in this protocol.
    static let warmGoScript = #"""
        key=$1
        state=
        trace=$2
        shift 2
        report() {
            read -r uptime rest < /proc/uptime
            cpu=null
            if [ -r /sys/fs/cgroup/cpu.stat ]; then
                while read -r field value; do
                    if [ "$field" = usage_usec ]; then cpu=$value; break; fi
                done < /sys/fs/cgroup/cpu.stat
            fi
            printf '{"event":"ci.go.warm","state":"%s","key":"%s","uptime_s":%s,"cpu_usec":%s}\n' "$1" "$key" "$uptime" "$cpu"
        }
        generation() {
            if [ -f "$state/last" ]; then cat "$state/last"; fi
        }
        run_go() {
            if [ "$trace" = 0 ]; then go "$@"; return; fi
            action=$1
            shift
            if go "$action" -x "$@" 2>>"$log"; then return 0; else code=$?; cat "$log" >&2; return "$code"; fi
        }
        report entered
        if command -v flock >/dev/null 2>&1; then
            state=$GOCACHE/.micropod-warm-go
            mkdir -p "$state"
            previous=$(generation)
            exec 9>>"$state/lock"
            if ! flock -n 9; then report waiting; flock -x 9; fi
            current=$(generation)
            if [ "$current" != "$previous" ] && [ "${current%% *}" = "$key" ]; then
                report joined
                exit 0
            fi
        else
            report uncoordinated
        fi
        if [ "$trace" = 1 ]; then log=$(mktemp); trap 'rm -f "$log"' EXIT; fi
        report preparing
        # Compile-only test preparation primes the exact vet actions used by go test.
        # /dev/null also supports multiple packages with the same basename. No test runs.
        run_go test -c -o /dev/null "$@" >/dev/null
        report tests_compiled
        run_go vet "$@" >&2
        if [ "$trace" = 1 ]; then
            awk -v key="$key" '
                /\/compile["\047]?[[:space:]]+-o / {c++}
                /\/vet["\047]?[[:space:]]/ && $NF ~ /\/vet\.cfg["\047]?$/ {v++}
                /\/link["\047]?[[:space:]]+-o / {l++}
                END {printf "{\"event\":\"ci.go.tools\",\"key\":\"%s\",\"compile\":%d,\"vet\":%d,\"link\":%d}\n", key,c,v,l}
            ' "$log"
        fi
        if [ -n "${state:-}" ]; then
            read -r token < /proc/sys/kernel/random/uuid
            printf '%s %s\n' "$key" "$token" > "$state/next"
            mv -f "$state/next" "$state/last"
        fi
        report ready
        """#
}
