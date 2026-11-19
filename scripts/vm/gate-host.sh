#!/usr/bin/env bash
# Host side of the runtime-authority release gate (docs/vm-release-gate.md):
# a pinned, signature-checked tart, a pinned macOS 26 image, and the
# migration kill matrix on throwaway clones. Everything lives under
# ~/micropod-gate-vm, so deleting that folder removes it all. It never runs
# cuttle or touches the host's Cuttlefish agent.
#
#   bash gate-host.sh tart                 install and verify tart
#   bash gate-host.sh base                 pull the image as gate-base
#   bash gate-host.sh clone <from> <to>    copy-on-write clone (VM stopped)
#   bash gate-host.sh run <vm>             boot with ~/micropod-rc shared
#   bash gate-host.sh key <vm>             let the host ssh in (VM running)
#   bash gate-host.sh stop <vm>
#   bash gate-host.sh rm <vm>
#   bash gate-host.sh matrix               G3 on clones of gate-legacy-base
#   bash gate-host.sh space                disk left, gate VMs
#   bash gate-host.sh results              the guests' PASS/FAIL table
#   bash gate-host.sh cleanup              stop and delete everything
set -u -o pipefail

HOME_DIR=$HOME/micropod-gate-vm
export TART_HOME=$HOME_DIR/tart
TART=$HOME_DIR/tart.app/Contents/MacOS/tart
RC_DIR=${MICROPOD_GATE_RC_DIR:-$HOME/micropod-rc}
KEY=$HOME_DIR/ssh_key
GUEST_RC="/Volumes/My Shared Files/rc"
GUEST_GATE="$GUEST_RC/runtime-authority-gate.sh"

# tart 2.41.1 (2026-10-15), Developer ID Cirrus Labs, Inc. (9M2P8L4D89).
TART_VERSION=2.41.1
TART_SHA256=e680a734febccfce7d4e910c1f7f13fc3b00f19a181c945e2d746de3214c32c2
TART_TEAM=9M2P8L4D89
# macos-tahoe-vanilla 26.6.2: SIP on, user admin/admin, 50 GB sparse disk.
IMAGE=ghcr.io/cirruslabs/macos-tahoe-vanilla
IMAGE=$IMAGE@sha256:eeec54bfe1f076e27786c5d92b89187a05b1d109b5071eb2dcdf02d596e34640

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need_tart() { [ -x "$TART" ] || die "run: bash $0 tart"; }

ssh_vm() {
  local ip
  ip=$("$TART" ip "$1" --wait 300) || die "no IP for $1"
  shift
  ssh -t -i "$KEY" -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "admin@$ip" "$@"
}

# wait_ssh <vm>: ssh answers and the shared folder is mounted (it mounts
# when the VM's automatic login completes).
wait_ssh() {
  local i
  for ((i = 0; i < 60; i++)); do
    ssh_vm "$1" test -f "'$GUEST_GATE'" >/dev/null 2>&1 && return 0
    sleep 10
  done
  return 1
}

boot() {
  local vm=$1 mode=${2:-}
  mkdir -p "$HOME_DIR/logs"
  # shellcheck disable=SC2086
  mkdir -p "$HOME_DIR/out"
  nohup "$TART" run "$vm" $mode --dir="rc:$RC_DIR:ro" \
    --dir="out:$HOME_DIR/out" >"$HOME_DIR/logs/$vm.log" 2>&1 &
  printf 'booting %s (log: %s)\n' "$vm" "$HOME_DIR/logs/$vm.log"
}

case "${1:-help}" in
  tart)
    mkdir -p "$HOME_DIR/download"
    cd "$HOME_DIR/download" || exit 1
    curl -fL -o tart.tar.gz \
      "https://github.com/cirruslabs/tart/releases/download/$TART_VERSION/tart.tar.gz" ||
      die "download failed"
    got=$(shasum -a 256 tart.tar.gz | cut -d' ' -f1)
    [ "$got" = "$TART_SHA256" ] || die "tart.tar.gz SHA-256 is $got"
    rm -rf x && mkdir x && tar -xzf tart.tar.gz -C x || exit 1
    codesign --verify --strict --deep \
      -R="anchor apple generic and certificate leaf[subject.OU] = \"$TART_TEAM\"" \
      x/tart.app || die "tart.app is not Cirrus Labs' Developer ID build"
    spctl -a -t exec x/tart.app || die "Gatekeeper rejects tart.app"
    rm -rf "$HOME_DIR/tart.app" && mv x/tart.app "$HOME_DIR/tart.app"
    "$TART" --version
    ;;
  base)
    need_tart
    free=$(df -g "$HOME" | awk 'NR == 2 { print $4 }')
    [ "$free" -ge 60 ] || die "only ${free} GB free; the image needs about 30 GB plus headroom"
    "$TART" clone "$IMAGE" gate-base || exit 1
    "$TART" set gate-base --cpu 4 --memory 8192
    "$TART" list
    ;;
  clone)
    need_tart
    "$TART" clone "${2:?from}" "${3:?to}"
    ;;
  run)
    need_tart
    boot "${2:?vm}"
    ;;
  key)
    need_tart
    [ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -f "$KEY"
    ip=$("$TART" ip "${2:?vm}" --wait 300) || die "no IP"
    printf 'password is: admin\n'
    ssh-copy-id -i "$KEY.pub" -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null "admin@$ip"
    ;;
  stop)
    need_tart
    "$TART" stop "${2:?vm}"
    ;;
  rm)
    need_tart
    "$TART" stop "${2:?vm}" >/dev/null 2>&1
    "$TART" delete "$2"
    ;;
  matrix)
    # G3: every checkpoint, without and with a reboot, each on its own clone
    # of the approved 0.13.3 VM. Results: ~/micropod-gate-vm/out/matrix.log
    need_tart
    [ -f "$KEY" ] || die "run 'key' on gate-legacy-base first"
    log=$HOME_DIR/out/matrix.log
    mkdir -p "$HOME_DIR/out"
    : >"$log"
    for point in staged neutralized plistWritten bootstrapped retired started; do
      for mode in plain rebooted; do
        vm=gate-k-$point-$mode
        printf '\n=== %s\n' "$vm" | tee -a "$log"
        "$TART" clone gate-legacy-base "$vm" || die "clone failed"
        boot "$vm" --no-graphics
        wait_ssh "$vm" || die "$vm never answered ssh"
        ssh_vm "$vm" bash "'$GUEST_GATE'" g3-kill "$point" 2>&1 | tee -a "$log"
        if [ "$mode" = rebooted ]; then
          ssh_vm "$vm" sudo shutdown -r now >/dev/null 2>&1
          sleep 30
          wait_ssh "$vm" || die "$vm did not come back"
          ssh_vm "$vm" bash "'$GUEST_GATE'" g3-check "$point" rebooted 2>&1 | tee -a "$log"
        else
          ssh_vm "$vm" bash "'$GUEST_GATE'" g3-check "$point" 2>&1 | tee -a "$log"
        fi
        "$TART" stop "$vm" >/dev/null 2>&1
        "$TART" delete "$vm"
      done
    done
    printf '\nchecks passed: %s, failed: %s (%s)\n' \
      "$(grep -c '  PASS ' "$log")" "$(grep -c '  FAIL ' "$log")" "$log"
    ! grep -q '  FAIL ' "$log"
    ;;
  space)
    df -h "$HOME" | awk 'NR == 2 { print "free on this disk: " $4 }'
    du -sh "$HOME_DIR" 2>/dev/null
    [ -x "$TART" ] && "$TART" list
    ;;
  results)
    column -t -s $'\t' "$HOME_DIR/out/results.tsv" 2>/dev/null
    [ -f "$HOME_DIR/out/matrix.log" ] && grep -cE '  (PASS|FAIL) ' "$HOME_DIR/out/matrix.log"
    ;;
  cleanup)
    if [ -x "$TART" ]; then
      for vm in $("$TART" list --source local --quiet 2>/dev/null); do
        "$TART" stop "$vm" >/dev/null 2>&1
      done
    fi
    rm -rf "$HOME_DIR"
    printf 'removed %s\n' "$HOME_DIR"
    ;;
  *)
    sed -n '2,18p' "$0"
    ;;
esac
