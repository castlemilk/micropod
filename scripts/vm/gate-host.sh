#!/bin/bash
# Host side of the runtime-authority release gate (docs/vm-release-gate.md):
# a pinned, signature-checked tart, a pinned macOS 26 image, and the
# migration kill matrix on throwaway clones. Everything lives under
# ~/micropod-gate-vm, so deleting that folder removes it all. It never runs
# cuttle or touches the host's Cuttlefish agent, and it refuses to boot a VM
# while any other virtual machine (Apple container, Micropod, Docker
# Desktop, another tart VM) runs on this Mac.
#
#   bash gate-host.sh preflight            what would stop a VM from booting
#   bash gate-host.sh tart                 install and verify tart
#   bash gate-host.sh base                 pull the image as gate-base
#   bash gate-host.sh key                  the ssh key the VMs will accept
#   bash gate-host.sh clone <from> <to>    copy-on-write clone (VM stopped)
#   bash gate-host.sh run <vm>             boot with ~/micropod-rc shared
#   bash gate-host.sh stop <vm>
#   bash gate-host.sh rm <vm>
#   bash gate-host.sh matrix               G3 on clones of gate-legacy-base
#   bash gate-host.sh need                 GB the gate needs free (number)
#   bash gate-host.sh space                disk left, gate VMs
#   bash gate-host.sh results              the guests' PASS/FAIL table
#   bash gate-host.sh cleanup              stop and delete everything
#
# Trust: the guest writes only ~/micropod-gate-vm/out. This script never
# writes there, refuses it if it holds a symbolic link, and prints guest text
# through `cat -v`. Its own logs are in ~/micropod-gate-vm/logs.
set -u -o pipefail

HOME_DIR=$HOME/micropod-gate-vm
export TART_HOME=$HOME_DIR/tart
TART=$HOME_DIR/tart.app/Contents/MacOS/tart
RC_DIR=${MICROPOD_GATE_RC_DIR:-$HOME/micropod-rc}
OUT=$HOME_DIR/out
LOGS=$HOME_DIR/logs
KEY=$HOME_DIR/ssh_key
GUEST_RC="/Volumes/My Shared Files/rc"
ROOT_GATE=/var/root/micropod-gate/runtime-authority-gate.sh
# Any virtual machine: Virtualization.framework's per-VM process (tart,
# Apple container, Micropod, Docker Desktop) and Apple container's runtime.
VM_PROCESSES='com.apple.Virtualization.VirtualMachine|container-runtime-linux'

# tart 2.41.1 (2026-10-15), Developer ID Cirrus Labs, Inc. (9M2P8L4D89).
TART_VERSION=2.41.1
TART_SHA256=e680a734febccfce7d4e910c1f7f13fc3b00f19a181c945e2d746de3214c32c2
TART_TEAM=9M2P8L4D89
# macos-tahoe-vanilla 26.6.2: SIP on, user admin/admin, 50 GB sparse disk.
IMAGE=ghcr.io/cirruslabs/macos-tahoe-vanilla
IMAGE=$IMAGE@sha256:eeec54bfe1f076e27786c5d92b89187a05b1d109b5071eb2dcdf02d596e34640
# Disk the gate needs, in GB. IMAGE_GB is the image's blocks once pulled: a
# 22 GB download into a 50 GB sparse disk, whose manifest bounds the written
# blocks between 23 and 47 GB (estimated at about 30). It counts only until
# the image is in tart's cache. WORK_GB is the clones' own writes and logs.
IMAGE_GB=35
WORK_GB=12

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need_tart() { [ -x "$TART" ] || die "run: bash $0 tart"; }

# has_vm <source> <name>: tart has it (false while tart is not installed).
has_vm() {
  [ -x "$TART" ] && "$TART" list --source "$1" --quiet 2>/dev/null | grep -qxF "$2"
}

# need_gb: GB that must be free for the rest of the gate. The image counts
# until it is pulled (in tart's cache, or already cloned as gate-base).
need_gb() {
  if has_vm oci "$IMAGE" || has_vm local gate-base; then
    printf '%s\n' "$WORK_GB"
  else
    printf '%s\n' "$((IMAGE_GB + WORK_GB))"
  fi
}

# preflight [wait]: no virtual machine runs on this Mac. With "wait", gives
# a VM this script just stopped up to a minute to exit.
preflight() {
  local i running
  for ((i = 0; i < 12; i++)); do
    running=$(pgrep -fl "$VM_PROCESSES")
    [ -z "$running" ] && return 0
    [ "${1:-}" = wait ] || break
    sleep 5
  done
  printf 'A virtual machine is running on this Mac:\n%s\n' "$running" | cat -v >&2
  die "stop it first (Micropod, Apple container, Docker Desktop or a tart VM); the gate runs alone"
}

ssh_vm() {
  local ip
  ip=$("$TART" ip "$1" --wait 300) || die "no IP for $1"
  shift
  ssh -t -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o PasswordAuthentication=no -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "admin@$ip" "$@"
}

# wait_ssh <vm>: ssh answers and the shared folder is mounted (it mounts
# when the VM's automatic login completes).
wait_ssh() {
  local i
  for ((i = 0; i < 60; i++)); do
    ssh_vm "$1" test -d "'$GUEST_RC'" >/dev/null 2>&1 && return 0
    sleep 10
  done
  return 1
}

boot() {
  local vm=$1 mode=${2:-}
  preflight wait
  mkdir -p "$LOGS" "$OUT"
  # shellcheck disable=SC2086
  nohup "$TART" run "$vm" $mode --dir="rc:$RC_DIR:ro" \
    --dir="out:$OUT" >"$LOGS/$vm.log" 2>&1 &
  printf 'booting %s (log: %s)\n' "$vm" "$LOGS/$vm.log"
}

# out_safe: the guest-written folder holds no symbolic link.
out_safe() {
  [ -d "$OUT" ] || return 0
  [ ! -L "$OUT" ] || die "$OUT is a symbolic link"
  [ -z "$(find -P "$OUT" -type l -print -quit)" ] ||
    die "$OUT holds a symbolic link; not reading it"
}

case "${1:-help}" in
  preflight)
    preflight
    printf 'no virtual machine runs on this Mac\n'
    ;;
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
    need=$(need_gb)
    [ "$free" -ge "$need" ] ||
      die "only ${free} GB free; the gate needs ${need} GB (the image ${IMAGE_GB} GB until it is pulled, then ${WORK_GB} GB for clones and logs)"
    "$TART" clone "$IMAGE" gate-base || exit 1
    "$TART" set gate-base --cpu 4 --memory 8192
    "$TART" list
    ;;
  key)
    # The VM's `harden` step installs this public key from the read-only
    # rc share; password ssh is then turned off.
    mkdir -p "$HOME_DIR"
    [ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C micropod-gate -f "$KEY"
    cp "$KEY.pub" "$RC_DIR/gate_key.pub"
    printf 'public key: %s\n' "$RC_DIR/gate_key.pub"
    ;;
  clone)
    need_tart
    "$TART" clone "${2:?from}" "${3:?to}"
    ;;
  run)
    need_tart
    boot "${2:?vm}"
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
    # of the approved, hardened ("harden matrix") 0.13.3 VM. The host runs
    # only the root-owned gate copy the VM's sudo rule allows.
    need_tart
    [ -f "$KEY" ] || die "run 'key' first"
    mkdir -p "$LOGS"
    log=$LOGS/matrix.log
    : >"$log"
    for point in staged neutralized plistWritten bootstrapped retired started; do
      for mode in plain rebooted; do
        vm=gate-k-$point-$mode
        printf '\n=== %s\n' "$vm" | tee -a "$log"
        "$TART" clone gate-legacy-base "$vm" || die "clone failed"
        boot "$vm" --no-graphics
        wait_ssh "$vm" || die "$vm never answered ssh"
        ssh_vm "$vm" sudo -n /bin/bash "$ROOT_GATE" g3-kill "$point" 2>&1 | cat -v | tee -a "$log"
        if [ "$mode" = rebooted ]; then
          ssh_vm "$vm" sudo -n /sbin/shutdown -r now >/dev/null 2>&1
          sleep 30
          wait_ssh "$vm" || die "$vm did not come back"
          ssh_vm "$vm" sudo -n /bin/bash "$ROOT_GATE" g3-check "$point" rebooted 2>&1 | cat -v | tee -a "$log"
        else
          ssh_vm "$vm" sudo -n /bin/bash "$ROOT_GATE" g3-check "$point" 2>&1 | cat -v | tee -a "$log"
        fi
        "$TART" stop "$vm" >/dev/null 2>&1
        "$TART" delete "$vm"
      done
    done
    printf '\nchecks passed: %s, failed: %s (%s)\n' \
      "$(grep -c '  PASS ' "$log")" "$(grep -c '  FAIL ' "$log")" "$log"
    ! grep -q '  FAIL ' "$log"
    ;;
  need)
    # GB the rest of the gate needs free on this disk (cuttle checks it
    # before it stops anything).
    need_gb
    ;;
  space)
    df -h "$HOME" | awk 'NR == 2 { print "free on this disk: " $4 }'
    printf 'the gate needs: %s GB\n' "$(need_gb)"
    du -sh "$HOME_DIR" 2>/dev/null
    [ -x "$TART" ] && "$TART" list
    ;;
  results)
    out_safe
    [ -f "$OUT/results.tsv" ] && cat -v "$OUT/results.tsv"
    [ -f "$LOGS/matrix.log" ] && grep -E '^=== |== g3' "$LOGS/matrix.log" | cat -v
    ;;
  cleanup)
    if [ -x "$TART" ]; then
      for vm in $("$TART" list --source local --quiet 2>/dev/null); do
        "$TART" stop "$vm" >/dev/null 2>&1
      done
    fi
    rm -rf "$HOME_DIR"
    rm -f "$RC_DIR/gate_key.pub"
    printf 'removed %s\n' "$HOME_DIR"
    ;;
  *)
    sed -n '2,25p' "$0"
    ;;
esac
