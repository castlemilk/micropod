#!/bin/bash
# Micropod runtime-authority release gate (docs/vm-release-gate.md). It
# replaces, kills and attacks the runtime helper on purpose, so it runs in one
# of two places:
#
# - a throwaway macOS 26 VM (the default), or
# - a real rig, with MICROPOD_GATE_RIG=1 ("rig mode"). Each rig runs the tests
#   for the upgrade it really takes: a rig without Micropod the fresh track (G1
#   G2 G5 G6 G7 G8), a rig on 0.13.3 with its SMAppService helper the legacy
#   track (G3 with one real kill, G9, G4). It ends upgraded to candidate A, the
#   release under test. Rig mode never changes the account's password, ssh or
#   sudo rules, and refuses the steps that need a throwaway machine (harden,
#   prepare-legacy, g4-before). `rig-begin <run-id>` marks the rig first; every
#   other step refuses without that root-owned marker, while a Cuttlefish agent
#   or GitHub runner or Docker Desktop runs, or as root.
#
#   bash runtime-authority-gate.sh harden          first, once per base VM
#   bash runtime-authority-gate.sh <step>          one step; PASS/FAIL lines
#   bash runtime-authority-gate.sh report          every result so far
#
# Every step first proves it runs in a gate VM (vm_guard): a hypervisor guest
# (kern.hv_vmm_present = 1) carrying the root-owned marker `harden` wrote,
# with no Cuttlefish agent or state and no RuntimeHost identity the gate did
# not create. `harden` itself needs a fresh guest: it sets a random password,
# key-only ssh, and (with "matrix") a sudo rule scoped to the matrix steps.
#
# Release candidates come from the shared folder (tart --dir=rc:<host dir>):
#   $RC/A/Micropod.<A>.tgz        candidate A (the release under test)
#   $RC/B/Micropod.<B>.tgz        candidate B, newer than A (G6, G7)
#   $RC/legacy/Micropod.0.13.3.tgz   the SMAppService release to migrate from
#   $RC/other-team/<binary>       optional: any other team's Developer ID binary
#   $RC/apple-development/<bin>   optional: an Apple Development-signed helper
#
# Results: $OUT/results.tsv and $OUT/logs (the host's ~/micropod-gate-vm/out).
# A step that needs a reboot records the checks it made first as its own
# line; the step it names records the rest. Its test passes only if both do.
# Exit codes: 0 every check passed, 1 a check failed, 75 the step needs a
# reboot (reboot, log in, run the step it names).
set -u -o pipefail
# sudo on macOS keeps the caller's PATH; the root copy the matrix runs must
# never resolve a command through it.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

RC=${MICROPOD_GATE_RC:-"/Volumes/My Shared Files/rc"}
GATE=/Users/Shared/micropod-gate
RH="/Library/Application Support/Micropod/RuntimeHost"
AUTH_LABEL=com.skunkworq.micropod.runtime.authority
LEGACY_LABEL=com.skunkworq.micropod.runtime.host
PLIST=/Library/LaunchDaemons/$AUTH_LABEL.plist
PROGRAM="$RH/authority/current/Micropod Runtime Setup.app/Contents/MacOS/MicropodRuntimeHost"
LEGACY_APP="/Applications/Micropod Runtime Setup.app"
SERVING="$RH/serving.json"
TEAM=WFTX6CN23F
REQ="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\""
REQ="$REQ and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
REQ="$REQ and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
CHECKPOINTS="staged neutralized plistWritten bootstrapped retired started"
MARKER=/var/db/micropod-gate-vm
ROOT_COPY=/var/root/micropod-gate/runtime-authority-gate.sh
# What launchd runs as the agent child (its plist and scripts, and the
# residual program), root-owned in a root-owned folder: no process of the
# admin user can swap them. The child's own outputs stay in $GATE.
CHILD_BIN=/var/db/micropod-gate-child
SUDOERS=/etc/sudoers.d/micropod-gate
STEP=${1:-help}

say() { printf '%s\n' "$*"; }
die() { printf 'refused: %s\n' "$*" >&2; exit 2; }

# Rig mode: the gate runs on a real rig (see the header).
case "${MICROPOD_GATE_RIG:-}" in
  "" | 0) RIG="" ;;
  1) RIG=1 ;;
  *) die "MICROPOD_GATE_RIG must be 1 or unset" ;;
esac
RIG_MARKER=/var/db/micropod-gate-rig
# Root's own rig-mode state: A's saved high-water marks, the "dirty" flag (a
# B test not yet undone by rig-reset), the boot stamp a reboot request writes.
RIG_DIR=/var/db/micropod-gate-rig.d
# Root-only copies: the program g2 swaps out, and the admin-owned but
# immutable CLI the R2 check runs as root.
SAVE_DIR=/var/root/micropod-gate-save
R2_DIR=/var/root/micropod-gate-r2
if [ -n "$RIG" ]; then
  [ "$(id -u)" != 0 ] || die "rig mode runs as the rig's admin user (it uses sudo itself), not as root"
  RC=${MICROPOD_GATE_RC:-"$HOME/micropod-rc"}
  MARKER=$RIG_MARKER
fi

# The user the gate acts for: this user, or the one sudo ran the matrix
# steps for.
if [ "$(id -u)" = 0 ]; then
  GATE_USER=${SUDO_USER:-}
  [ -n "$GATE_USER" ] && [ "$GATE_USER" != root ] || die "run as the VM's admin user, not root"
else
  GATE_USER=$(id -un)
fi

# vm_guard [fresh]: this is a gate VM and nothing real is on it. "fresh"
# (harden) requires that no gate has marked it yet and no runtime exists.
vm_guard() {
  [ "$(sysctl -n kern.hv_vmm_present 2>/dev/null)" = 1 ] ||
    die "not a virtual machine (kern.hv_vmm_present != 1): never run the gate on a real Mac"
  if [ "${1:-}" = fresh ]; then
    [ ! -e "$MARKER" ] || die "$MARKER exists: this VM is already hardened"
  else
    [ -f "$MARKER" ] && [ ! -L "$MARKER" ] && [ "$(stat -f %u "$MARKER")" = 0 ] ||
      die "no root-owned $MARKER: run 'harden' in a fresh gate VM first"
    head -1 "$MARKER" | grep -q '^micropod-gate-vm ' || die "$MARKER is not a gate marker"
    # Written only once every hardening check passed.
    grep -q '^hardened ' "$MARKER" || die "$MARKER says the VM was not hardened: run 'harden' again"
  fi
  if pgrep -fil 'cuttle|cuttlefish' >/dev/null; then
    die "a Cuttlefish process runs here: $(pgrep -fil 'cuttle|cuttlefish' | head -3 | tr '\n' ' ')"
  fi
  local found
  found=$(sudo find /Users /var/root -maxdepth 2 -name .cuttlefish 2>/dev/null | head -1)
  [ -z "$found" ] || die "Cuttlefish state exists: $found"
  found=$(sudo find /Applications /Library/LaunchAgents /Library/LaunchDaemons /Users/*/Library/LaunchAgents \
    -maxdepth 1 -iname '*cuttlefish*' 2>/dev/null | head -1)
  [ -z "$found" ] || die "a Cuttlefish install exists: $found"
  if sudo test -e "$RH/identity.json"; then
    [ "${1:-}" != fresh ] || die "a RuntimeHost identity exists: not a fresh VM"
    local instance
    instance=$(sudo plutil -extract instance raw -o - "$RH/identity.json" 2>/dev/null)
    [ -n "$instance" ] && grep -qx "identity $instance" "$MARKER" ||
      die "RuntimeHost identity ${instance:-unreadable} was not created by the gate"
  fi
}

# rig_busy: a Cuttlefish process that runs work or could take it on this rig:
# the agent and its runtime, a supervised GitHub runner, a runner pool. The
# cuttle CLI driving the gate is none of them.
rig_busy() {
  pgrep -fl '/CuttlefishAgent\.app/Contents/|/Cuttlefish Agent\.app/Contents/|/\.cuttlefish/github-runners/|/\.cuttlefish/bin/cuttle-gha-pool-' 2>/dev/null |
    head -3 | tr '\n' ' '
}

# rig_track: the track rig-begin recorded (fresh or legacy).
rig_track() { sed -n 's/^track //p' "$RIG_MARKER" 2>/dev/null | head -1; }

# rig_guard [begin]: rig mode's guard. Nothing of Cuttlefish's runs or takes
# work, Docker Desktop is not running, and (but for rig-begin) rig-begin
# marked this rig. rig-end, which only removes the gate's files, needs none
# of it.
rig_guard() {
  local busy
  busy=$(rig_busy)
  [ -z "$busy" ] || die "Cuttlefish runs work here ($busy): stop the agent and its runners first (cuttle micropod gate run does)"
  if pgrep -f '/Applications/Docker\.app/Contents/MacOS/' >/dev/null 2>&1; then
    die "Docker Desktop runs here: quit it first (cuttle micropod gate run does)"
  fi
  [ "${1:-}" != begin ] || return 0
  [ -f "$RIG_MARKER" ] && [ ! -L "$RIG_MARKER" ] && [ "$(stat -f %u "$RIG_MARKER")" = 0 ] ||
    die "no root-owned $RIG_MARKER: run 'rig-begin <run-id>' first"
  head -1 "$RIG_MARKER" | grep -q '^micropod-gate-rig ' || die "$RIG_MARKER is not a gate marker"
}

# rig_needs <track>: the step belongs to that track.
rig_needs() {
  [ -z "$RIG" ] || [ "$(rig_track)" = "$1" ] ||
    die "$STEP is a $1-track step; this rig is on the $(rig_track) track"
}

# rig_stamp: before a reboot, root records this boot; rig_rebooted: the
# machine booted again since. Only root can write the stamp.
rig_stamp() { sysctl -n kern.boottime | sudo tee "$RIG_DIR/boot" >/dev/null; }
rig_rebooted() {
  sudo test -s "$RIG_DIR/boot" && [ "$(sysctl -n kern.boottime)" != "$(sudo cat "$RIG_DIR/boot")" ]
}
rig_after_reboot() {
  [ -z "$RIG" ] || rig_rebooted || die "this Mac has not rebooted since the step that asked for it: reboot first (sudo shutdown -r now)"
}

# rig_on_a [to-b]: a fresh-track test starts from A, as each VM test starts
# from a clone of the A base: rig-save ran, no B test is left un-reset, and
# A serves. "to-b" (the tests that move the rig to B) then sets the dirty
# flag that only a passing rig-reset clears.
rig_on_a() {
  [ -n "$RIG" ] || return 0
  rig_needs fresh
  sudo test -f "$RIG_DIR/component-state.json" || die "rig-save has not run: run it after g1"
  ! sudo test -e "$RIG_DIR/dirty" || die "the rig is not back on A since $(sudo cat "$RIG_DIR/dirty"): run rig-reset"
  wait_serving "$(version_of "$(unpack A)/Micropod.app")" 30 || die "A does not serve: run rig-reset"
  if [ "${1:-}" = to-b ]; then printf '%s\n' "$STEP" | sudo tee "$RIG_DIR/dirty" >/dev/null; fi
}

# marks_field <file> <key>: one high-water mark, or nothing (root reads it).
marks_field() { sudo plutil -extract "$2" raw -o - "$1" 2>/dev/null; }
# marks_match: the marks are the saved ones, field by field (the file's key
# order changes each time root rewrites it).
marks_match() {
  local saved="$RIG_DIR/component-state.json" live="$RH/component-state.json" key
  for key in highestVersion securityFloor; do
    [ "$(marks_field "$saved" "$key")" = "$(marks_field "$live" "$key")" ] || return 1
  done
}

# rig_undo_attack: what an attack that should have failed moved, back where
# it was (a rig has no clone to throw away). Only what is really gone is put
# back, so nothing an admin process left in $GATE can replace a root file.
rig_undo_attack() {
  [ -n "$RIG" ] || return 0
  local moved="$GATE/attack-moved" support="/Library/Application Support/Micropod"
  if present "$moved/p" && ! present "$PLIST"; then sudo mv "$moved/p" "$PLIST"; fi
  if present "$moved/m" && ! present "$support"; then sudo mv "$moved/m" "$support"; fi
  if present "$moved/l.app" && ! present "$LEGACY_APP"; then sudo mv "$moved/l.app" "$LEGACY_APP"; fi
  if present "$GATE/moved.app" && ! legacy_immutable; then
    sudo rm -rf "$LEGACY_APP"
    sudo mv "$GATE/moved.app" "$LEGACY_APP"
  fi
  sudo rm -rf "$moved" "$GATE/moved.app"
}

# allow_identity: the runtime the gate just installed may exist from now on.
allow_identity() {
  local instance
  instance=$(sudo plutil -extract instance raw -o - "$RH/identity.json" 2>/dev/null) || return 1
  [ -n "$instance" ] || return 1
  grep -qx "identity $instance" "$MARKER" ||
    printf 'identity %s\n' "$instance" | sudo tee -a "$MARKER" >/dev/null
}

if [ -n "$RIG" ]; then
  case "$STEP" in
    help | report) ;;
    harden | prepare-legacy | g4-before | g4-before-after)
      die "$STEP needs a throwaway VM: rig mode never runs it" ;;
    rig-begin) rig_guard begin ;;
    rig-end) ;;
    *) rig_guard ;;
  esac
else
  case "$STEP" in
    help | report) ;;
    rig-*) die "$STEP is a rig-mode step (MICROPOD_GATE_RIG=1)" ;;
    harden) vm_guard fresh ;;
    *) vm_guard ;;
  esac
fi

# Results and logs go to the host's writable share when there is one, so
# they outlive a deleted clone. On a rig, to the folder cuttle names.
if [ -n "$RIG" ]; then
  OUT=${MICROPOD_GATE_OUT:-"$HOME/micropod-gate-rig/out"}
  [ ! -L "$OUT" ] || die "$OUT is a symbolic link"
  mkdir -p "$OUT" || die "cannot create $OUT"
else
  OUT=${MICROPOD_GATE_OUT:-"/Volumes/My Shared Files/out"}
  [ -d "$OUT" ] && [ -w "$OUT" ] || OUT=$GATE
fi
if [ -n "$RIG" ] && { [ -e "$GATE" ] || [ -L "$GATE" ]; }; then
  # The gate's working folder is this user's, mode 0700: /Users/Shared lets
  # any local account create it first.
  if [ -L "$GATE" ] || [ ! -d "$GATE" ] || [ "$(stat -f %u "$GATE")" != "$(id -u)" ] ||
    [ "$(stat -f %Lp "$GATE")" != 700 ]; then
    [ "$STEP" = rig-begin ] || die "$GATE is not this user's private folder: run rig-begin again"
    sudo rm -rf "$GATE" || die "cannot remove $GATE"
  fi
fi
[ -z "$RIG" ] || [ -d "$GATE" ] || mkdir -m 0700 "$GATE" || die "cannot create $GATE"
mkdir -p "$GATE/unpack" "$OUT/logs"
FAILED=0
# INCOMPLETE: a reason the step could not test what it should (an input is
# missing, or its attacker never ran). Never a pass.
INCOMPLETE=""

# check <description> <command...>: one PASS/FAIL line.
check() {
  local what=$1
  shift
  if "$@" >>"$OUT/logs/$STEP.log" 2>&1; then
    say "  PASS  $what"
  else
    say "  FAIL  $what"
    FAILED=1
  fi
}
refuse() { ! "$@"; }

# incomplete <reason>: the step cannot pass, but nothing failed either.
incomplete() {
  say "  INCOMPLETE  $*"
  [ -n "$INCOMPLETE" ] || INCOMPLETE=$*
}

# verdict [BASELINE|INCOMPLETE]: FAIL if a check failed, then INCOMPLETE,
# then the step's own verdict (PASS by default).
verdict() {
  if [ "$FAILED" -ne 0 ]; then
    printf 'FAIL\n'
  elif [ -n "$INCOMPLETE" ]; then
    printf 'INCOMPLETE\n'
  else
    printf '%s\n' "${1:-PASS}"
  fi
}

record() {
  printf '%s\t%s\t%s\n' "$(date '+%F %T')" "$STEP" "$1" >>"$OUT/results.tsv"
  say "== $STEP: $1"
}

result() {
  local v
  v=$(verdict "${1:-}")
  record "$v"
  [ "$v" = FAIL ] && exit 1
  exit 0
}

human() {
  say ""
  say ">>> HUMAN STEP: $*"
  read -r -p ">>> Press Enter when done (Ctrl-C to stop) " _
}

# needs_reboot <step>: record the checks made so far (the step after the
# reboot starts with none), then ask for the reboot.
needs_reboot() {
  [ -z "$RIG" ] || rig_stamp
  record "$(verdict)"
  printf '%s\n' "$1" >"$GATE/next"
  say ""
  say ">>> REBOOT: sudo shutdown -r now"
  say ">>> After logging in again: bash $0 $1"
  exit 75
}

# unpack <name>: $GATE/unpack/<name>/{Micropod.app,micropod}
unpack() {
  local dir="$GATE/unpack/$1" tgz n ver
  n=$(find "$RC/$1" -maxdepth 1 -name 'Micropod.*.tgz' 2>/dev/null | grep -c .)
  [ "$n" -eq 1 ] || { say "need exactly one $RC/$1/Micropod.*.tgz (found $n)" >&2; exit 1; }
  tgz=$(find "$RC/$1" -maxdepth 1 -name 'Micropod.*.tgz')
  ver=${tgz##*/Micropod.}
  ver=${ver%.tgz}
  [[ "$ver" =~ ^[0-9]+(\.[0-9]+){2}$ ]] || { say "$tgz: not a Micropod.<version>.tgz" >&2; exit 1; }
  if [ -d "$dir/Micropod.app" ] && [ "$(version_of "$dir/Micropod.app" 2>/dev/null)" != "$ver" ]; then
    rm -rf "$dir"
  fi
  if [ ! -d "$dir/Micropod.app" ]; then
    mkdir -p "$dir"
    tar -xzf "$tgz" -C "$dir" || exit 1
    if [ -n "$RIG" ]; then
      # Root later installs from here: only the signed release is used.
      codesign --verify --strict --deep -R="$REQ" "$dir/Micropod.app" >&2 &&
        codesign --verify --strict -R="$REQ" "$dir/micropod" >&2 &&
        [ "$(version_of "$dir/Micropod.app")" = "$ver" ] ||
        { rm -rf "$dir"; say "$tgz is not the signed Micropod $ver" >&2; exit 1; }
    fi
  fi
  printf '%s\n' "$dir"
}

version_of() {
  defaults read "$1/Contents/Info.plist" CFBundleShortVersionString
}

# root_cli <name>: the documented copy into a root-only directory, then the
# signature check on that copy. Prints the copy's path.
root_cli() {
  local src ver dst
  src=$(unpack "$1") || return 1
  ver=$(version_of "$src/Micropod.app")
  [[ "$ver" =~ ^[0-9]+(\.[0-9]+){2}$ ]] || return 1
  dst=/var/root/micropod-install/$ver
  sudo install -d -o root -g wheel -m 0700 /var/root/micropod-install
  sudo rm -rf "$dst"
  sudo install -d -o root -g wheel -m 0700 "$dst"
  sudo ditto --noextattr --noacl "$src/micropod" "$dst/micropod"
  sudo chown root:wheel "$dst/micropod"
  sudo chmod 0755 "$dst/micropod"
  sudo codesign --verify --strict -R="$REQ" "$dst/micropod" >&2 || return 1
  printf '%s\n' "$dst/micropod"
}

# r2_cli: A's CLI owned by the admin user, for the R2 check (install-authority
# refuses a CLI the invoking administrator owns). It is immutable (schg) in a
# root-owned folder, so root runs exactly the signed CLI. Prints its path.
r2_cli() {
  local src
  src=$(unpack A) || return 1
  sudo chflags -R noschg "$R2_DIR" 2>/dev/null
  sudo rm -rf "$R2_DIR"
  sudo install -d -o root -g wheel -m 0755 "$R2_DIR" || return 1
  sudo ditto --noextattr --noacl "$src/micropod" "$R2_DIR/micropod" || return 1
  sudo codesign --verify --strict -R="$REQ" "$R2_DIR/micropod" >&2 || return 1
  sudo chown "$GATE_USER" "$R2_DIR/micropod" && sudo chmod 0755 "$R2_DIR/micropod" &&
    sudo chflags schg "$R2_DIR/micropod" || return 1
  printf '%s\n' "$R2_DIR/micropod"
}

cdhash12() {
  local setup="$1/Contents/Helpers/Micropod Runtime Setup.app"
  codesign -dvvv "$setup" 2>&1 | sed -n 's/^CDHash=//p' | cut -c1-12
}

# install_authority <name> [checkpoint]: the administrator procedure. With
# a checkpoint, a root-owned gate-kill.json (that checkpoint, this CLI's
# CDHash, a 30-minute expiry) makes the CLI die there like a SIGKILL, once.
install_authority() {
  local name=$1 point=${2:-} cli app cdhash
  cli=$(root_cli "$name") || return 1
  app="$(unpack "$name")/Micropod.app"
  sudo rm -f "$RH/gate-kill.json"
  if [ -n "$point" ]; then
    cdhash=$(sudo codesign -dvvv "$cli" 2>&1 | sed -n 's/^CDHash=//p')
    printf '{"checkpoint":"%s","cdhash":"%s","expiresAt":%s}' \
      "$point" "$cdhash" "$(($(date +%s) + 1800))" | sudo tee "$RH/gate-kill.json" >/dev/null
    sudo chown root:wheel "$RH/gate-kill.json"
    sudo chmod 0600 "$RH/gate-kill.json"
  fi
  sudo "$cli" runtime install-authority --app "$app" --confirm "$(cdhash12 "$app")"
}

# as_user <command...>: as the admin user, also when sudo runs this script
# as root (the helper serves only accounts with uid >= 500).
as_user() {
  if [ "$(id -u)" = 0 ]; then sudo -u "$GATE_USER" -H "$@"; else "$@"; fi
}
user_cli() { as_user "$(unpack "$1")/micropod" "${@:2}"; }

# status_field <name> <key>: a field of the helper's status reply.
status_field() {
  local out="$GATE/status.json"
  user_cli "$1" --json runtime operation >"$out" 2>/dev/null || return 1
  plutil -extract "$2" raw -o - "$out" 2>/dev/null
}

authority_print() { sudo launchctl print "system/$AUTH_LABEL" 2>/dev/null; }
authority_running() { authority_print | grep -q $'^\tstate = running'; }
authority_pid() { authority_print | sed -n $'s/^\tpid = //p'; }
legacy_loaded() { sudo launchctl print "system/$LEGACY_LABEL" >/dev/null 2>&1; }
legacy_disabled() {
  sudo launchctl print-disabled system |
    grep -Eq "\"$LEGACY_LABEL\" => (disabled|true)"
}
serving_field() { sudo plutil -extract "$1" raw -o - "$SERVING" 2>/dev/null; }

# wait_serving <version> [seconds]: the authority's live process wrote the
# serving record and it names <version>.
wait_serving() {
  local want=$1 limit=${2:-90} i
  for ((i = 0; i < limit; i += 3)); do
    if authority_running && [ "$(serving_field pid)" = "$(authority_pid)" ] &&
      [ "$(serving_field version)" = "$want" ]; then
      return 0
    fi
    sleep 3
  done
  return 1
}

plist_exact() {
  [ "$(stat -f '%Su:%Sg %Lp' "$PLIST")" = "root:wheel 644" ] &&
    plutil -lint "$PLIST" >/dev/null &&
    [ "$(plutil -extract Program raw -o - "$PLIST")" = "$PROGRAM" ]
}

# helper_pids: runtime helper processes (pgrep -x would compare the
# kernel's 16-character process name, which truncates this one).
helper_pids() { pgrep -f 'MicropodRuntimeHost$' | sort; }

# helpers_alive: runtime helper processes alive across 15 seconds (a
# contender that loses the state lock exits at once).
helpers_alive() {
  local first second
  first=$(helper_pids)
  sleep 15
  second=$(helper_pids)
  comm -12 <(printf '%s\n' "$first") <(printf '%s\n' "$second") | grep -c .
}
at_most_one_helper() { [ "$(helpers_alive)" -le 1 ]; }

# no_identifier <id>: no root runtime helper runs code signed as <id>.
no_identifier() {
  local pid
  for pid in $(helper_pids); do
    sudo codesign -dv "$pid" 2>&1 | grep -q "^Identifier=$1\$" && return 1
  done
  return 0
}

legacy_immutable() { stat -f '%Sf' "$LEGACY_APP" | grep -q schg; }

finished() {
  local name=$1 ver
  ver=$(version_of "$(unpack "$name")/Micropod.app")
  check "authority plist is root:wheel 0644 and names the program" plist_exact
  check "authority serves $ver (live pid wrote serving.json)" wait_serving "$ver"
  check "legacy job is not loaded" refuse legacy_loaded
  check "legacy job is disabled" legacy_disabled
  check "replies come from the authority's service" \
    test "$(status_field "$name" helperService)" = "$AUTH_LABEL"
  check "the helper reports itself protected" \
    test "$(status_field "$name" componentProtection)" = protected
  check "at most one helper process" at_most_one_helper
}

poll_operation() {
  local name=$1 limit=${2:-1800} i phase
  for ((i = 0; i < limit; i += 5)); do
    phase=$(status_field "$name" phase)
    case "$phase" in
      idle | completed) return 0 ;;
      failed | blocked | cancelled | recoveryRequired) return 1 ;;
    esac
    sleep 5
  done
  return 1
}

# poll_component <name> <phases>: the component update settles as one of
# <phases> (a regular expression).
poll_component() {
  local name=$1 want=$2 limit=${3:-900} i phase
  for ((i = 0; i < limit; i += 5)); do
    phase=$(status_field "$name" componentUpdate.phase)
    [[ "$phase" =~ ^($want)$ ]] && return 0
    case "$phase" in
      completed | rolledBack | refused | recoveryRequired) return 1 ;;
    esac
    sleep 5
  done
  return 1
}

desktop() {
  local src
  src=$(unpack "$1") || return 1
  sudo rm -rf /Applications/Micropod.app
  sudo ditto "$src/Micropod.app" /Applications/Micropod.app
}

# gate_fault <name> <crash|hang> | gate_fault off: arm a fault for exactly
# that release's helper (version and SHA-256), expiring in an hour.
gate_fault() {
  local file="$RH/gate-fault.json" app helper
  if [ "$1" = off ]; then sudo rm -f "$file"; return; fi
  app="$(unpack "$1")/Micropod.app"
  helper="$app/Contents/Helpers/Micropod Runtime Setup.app/Contents/MacOS/MicropodRuntimeHost"
  printf '{"version":"%s","helperSHA256":"%s","fault":"%s","expiresAt":%s}' \
    "$(version_of "$app")" "$(shasum -a 256 "$helper" | cut -d' ' -f1)" "$2" \
    "$(($(date +%s) + 3600))" | sudo tee "$file" >/dev/null
  sudo chown root:wheel "$file"
  sudo chmod 0600 "$file"
}

# install_child_file <name> <mode>: stdin, written by root straight into the
# root-owned CHILD_BIN (no file the admin user could change on the way).
# Prints its path.
install_child_file() {
  local dst="$CHILD_BIN/$1"
  sudo install -d -o root -g wheel -m 0755 "$CHILD_BIN" || return 1
  sudo rm -f "$dst"
  sudo tee "$dst" >/dev/null || return 1
  sudo chown root:wheel "$dst" && sudo chmod "$2" "$dst" || return 1
  printf '%s\n' "$dst"
}

# child_output <path>: what the child wrote: a regular file, not a link,
# owned by the admin user. Nothing else is read as the child's output.
child_output() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ "$(stat -f %u "$1")" = "$(id -u "$GATE_USER")" ]
}

# present <path>: anything at all is there, a dangling link included.
present() { [ -e "$1" ] || [ -L "$1" ]; }

# child_prologue: the first line of every agent-child script. The child
# records that it ran, its parent (launchd starts a LaunchAgent: pid 1) and its
# session, before it does anything else.
child_prologue() {
  # shellcheck disable=SC2016 # $PPID and launchctl expand in the child
  printf 'printf "%%s %%s\\n" "$PPID" "$(/bin/launchctl managername 2>/dev/null)" >%q\n' "$GATE/child.started"
}

# as_agent_child <script>: run <script> as this user from a user LaunchAgent,
# the context a job the Cuttlefish agent spawns runs in. Returns 2 when the
# child never started (it wrote no child.started), and 0 otherwise, with
# what the child and launchd recorded in CHILD_PPID, CHILD_SESSION,
# CHILD_RUNS and CHILD_EXIT. Only a child that never started may make a test
# INCOMPLETE: child_checks fails one that started but did not run as an
# agent child does, to its end.
as_agent_child() {
  [ "$(id -u)" != 0 ] || die "agent-child attacks run as the admin user"
  local plist="$CHILD_BIN/dev.micropod.gate.child.plist"
  local target print="" i
  target="gui/$(id -u)/dev.micropod.gate.child"
  rm -f "$GATE/child.done" "$GATE/child.started"
  CHILD_PPID="" CHILD_SESSION="" CHILD_RUNS="" CHILD_EXIT=""
  # The plist too is root's, like /Library/LaunchAgents: the user cannot
  # change what launchd runs between this and the bootstrap.
  sudo install -d -o root -g wheel -m 0755 "$CHILD_BIN"
  sudo rm -f "$plist"
  sudo plutil -create xml1 "$plist"
  sudo plutil -insert Label -string dev.micropod.gate.child "$plist"
  sudo plutil -insert ProgramArguments -array "$plist"
  sudo plutil -insert ProgramArguments -string /bin/bash -append "$plist"
  sudo plutil -insert ProgramArguments -string "$1" -append "$plist"
  sudo plutil -insert RunAtLoad -bool true "$plist"
  sudo chown root:wheel "$plist"
  sudo chmod 0644 "$plist"
  launchctl bootstrap "gui/$(id -u)" "$plist"
  for ((i = 0; i < 60; i++)); do
    present "$GATE/child.done" && break
    sleep 1
  done
  # launchd records the run once the child has exited.
  for ((i = 0; i < 10; i++)); do
    print=$(launchctl print "$target" 2>&1)
    printf '%s\n' "$print" | grep -q 'state = running' || break
    sleep 1
  done
  printf '%s\n' "$print" | grep -E 'state =|runs =|last exit code' >>"$OUT/logs/$STEP.log"
  CHILD_RUNS=$(printf '%s\n' "$print" | sed -n 's/^[[:space:]]*runs = \([0-9][0-9]*\)$/\1/p' | head -1)
  CHILD_EXIT=$(printf '%s\n' "$print" | sed -n 's/^[[:space:]]*last exit code = //p' | head -1)
  launchctl bootout "$target" 2>/dev/null
  sudo rm -f "$plist"
  if ! present "$GATE/child.started"; then
    say "  (the agent-spawned child never started: launchctl bootstrap gui/$(id -u) did not run it)"
    return 2
  fi
  # Something is there: only a plain file of the admin user's is read, and
  # anything else fails child_checks.
  if child_output "$GATE/child.started"; then
    read -r CHILD_PPID CHILD_SESSION <"$GATE/child.started"
  fi
  printf 'agent child: parent pid %s, session %s, launchd runs %s, last exit code %s\n' \
    "$CHILD_PPID" "$CHILD_SESSION" "${CHILD_RUNS:-?}" "${CHILD_EXIT:-?}" >>"$OUT/logs/$STEP.log"
  return 0
}

launchd_ran_it() { [ "${CHILD_RUNS:-0}" -ge 1 ] && [ "${CHILD_EXIT:-}" = 0 ]; }

# child_checks: the agent child that started ran as one, to its end.
child_checks() {
  check "the agent child ran to its end" child_output "$GATE/child.done"
  check "launchd started it (parent pid 1)" test "${CHILD_PPID:-}" = 1
  check "it ran in the console user's GUI session (Aqua)" test "${CHILD_SESSION:-}" = Aqua
  check "launchd counted its run (runs >= 1, last exit code 0)" launchd_ran_it
}

attacker_script() {
  # Each attempt appends "<name> ok" if it succeeded (it must not). The child
  # creates attack.out itself, so a stale one cannot stand in for it.
  rm -f "$GATE/attack.out"
  rm -rf "$GATE/attack-moved"
  mkdir -p "$GATE/attack-moved"
  {
    printf '%s\n' '#!/bin/bash'
    child_prologue
    printf 'out=%q\n' "$GATE/attack.out"
    printf ': >"$out"\n'
    printf 'try() { n=$1; shift; "$@" 2>/dev/null && echo "$n ok" >>"$out"; }\n'
    printf 'try plist-write sh -c %q\n' "echo x >>'$PLIST'"
    printf 'try plist-move mv %q %q\n' "$PLIST" "$GATE/attack-moved/p"
    printf 'try plist-remove rm -f %q\n' "$PLIST"
    printf 'try program-write sh -c %q\n' "echo x >>'$PROGRAM'"
    printf 'try runtimehost-create touch %q\n' "$RH/authority/x"
    printf 'try runtimehost-acl chmod +a "everyone allow write" %q\n' "$RH"
    printf 'try support-move mv %q %q\n' "/Library/Application Support/Micropod" "$GATE/attack-moved/m"
    printf 'try bootout launchctl bootout system/%s\n' "$AUTH_LABEL"
    printf 'try disable launchctl disable system/%s\n' "$AUTH_LABEL"
    printf 'try kickstart launchctl kickstart -k system/%s\n' "$AUTH_LABEL"
    printf 'try legacy-move mv %q %q\n' "$LEGACY_APP" "$GATE/attack-moved/l.app"
    printf 'try legacy-write sh -c %q\n' \
      "echo x >>'$LEGACY_APP/Contents/MacOS/MicropodRuntimeHost'"
    printf 'try legacy-flags chflags -R noschg %q\n' "$LEGACY_APP"
    printf 'touch %q\n' "$GATE/child.done"
  } | install_child_file attack.sh 0755
}

# attack_clean: the child's attack.out is a plain file of its own and empty
# (absent: nothing was attempted, which child_checks and the attempts check
# catch). Anything else there counts as a successful attempt.
attack_clean() {
  present "$GATE/attack.out" || return 0
  child_output "$GATE/attack.out" && [ ! -s "$GATE/attack.out" ]
}

# plant_residual: the reviewer's residual as an admin-group process: move the
# legacy bundle aside and put an ad-hoc helper in its place. Returns 0 when it
# was planted (whatever the child's markers say), 2 when the child never
# started (nothing was tried), and 1 otherwise.
plant_residual() {
  local s evil
  # Nothing installed is nothing tried (2), never "planting failed" (1).
  evil=$(printf '#!/bin/sh\nid -u >%q\nexec sleep 600\n' "$GATE/residual" | install_child_file evil.sh 0755) || return 2
  s=$({
    printf '%s\n' '#!/bin/bash'
    child_prologue
    printf 'app=%q\n' "$LEGACY_APP"
    printf 'mv "$app" %q && ditto %q "$app" &&\n' "$GATE/moved.app" "$GATE/moved.app"
    printf '  cp %q "$app/Contents/MacOS/MicropodRuntimeHost" &&\n' "$evil"
    printf '  echo planted >%q\n' "$GATE/planted"
    printf 'touch %q\n' "$GATE/child.done"
  } | install_child_file plant.sh 0755) || return 2
  rm -f "$GATE/planted" "$GATE/residual"
  as_agent_child "$s"
  local ran=$?
  # Anything at all where the planter reports success counts as planted.
  present "$GATE/planted" && return 0
  [ "$ran" -eq 2 ] && return 2
  return 1
}

# variant <name> <binary>: launchd must refuse to spawn the authority job
# with <binary> as its program, and the original must serve again after.
variant() {
  local name=$1 bin=$2 saved="$SAVE_DIR/program.saved" ver pid_before
  ver=$(serving_field version)
  pid_before=$(serving_field pid)
  # Renamed into place, never written over the running executable.
  sudo install -d -o root -g wheel -m 0700 "$SAVE_DIR"
  sudo cp "$PROGRAM" "$saved"
  sudo cp "$bin" "$PROGRAM.gate"
  sudo mv -f "$PROGRAM.gate" "$PROGRAM"
  sudo launchctl kickstart -k "system/$AUTH_LABEL" 2>/dev/null
  sleep 20
  check "$name: launchd does not run it" refuse authority_running
  check "$name: no new serving record" \
    test "$(serving_field pid)" = "$pid_before"
  authority_print | grep -iE 'last exit|spawn|reason' >>"$OUT/logs/$STEP.log"
  sudo log show --last 2m --predicate 'process == "launchd"' 2>/dev/null |
    grep -iE 'constraint|codesign' | tail -5 >>"$OUT/logs/$STEP.log"
  sudo cp "$saved" "$PROGRAM.gate"
  sudo mv -f "$PROGRAM.gate" "$PROGRAM"
  sudo launchctl kickstart -k "system/$AUTH_LABEL" 2>/dev/null
  check "$name: the original serves again" wait_serving "$ver"
}

# rollback_refused <name>: a rollback is refused for the security floor.
rollback_refused() {
  local out="$GATE/rollback.out"
  user_cli "$1" runtime update --rollback >"$out" 2>&1
  grep -q 'security floor' "$out" ||
    [ "$(status_field "$1" componentUpdate.phase)" = refused ]
}

any_flags() {
  [ -n "$(sudo find "$1" \( -flags +uchg -o -flags +schg -o -flags +uappnd \
    -o -flags +sappnd -o -flags +hidden -o -flags +nodump \) -print)" ]
}

case "$STEP" in
  g1)
    # Fresh install on a VM (or rig) that never had Micropod.
    rig_needs fresh
    app="$(unpack A)/Micropod.app"
    check "Gatekeeper accepts Micropod.app (notarized Developer ID)" \
      spctl -a -t exec "$app"
    r2=$(r2_cli) || r2=/nonexistent/micropod
    check "the R2 copy is A's signed CLI, owned by $GATE_USER and immutable" test "$r2" = "$R2_DIR/micropod"
    check "a user-owned CLI is refused as root (R2)" refuse sudo \
      "$r2" runtime install-authority --app "$app" --confirm x
    check "nothing was installed by the refused run" test ! -e "$PLIST"
    check "install-authority from the root-only copy" install_authority A
    finished A
    desktop A
    check "the dedicated runtime installs" user_cli A runtime install
    check "the install settles" poll_operation A
    check "the gate records the runtime it created" allow_identity
    if [ -n "$RIG" ]; then
      human "Note whether a 'Background Items Added' notice appeared on this Mac (expected once, for the new LaunchDaemon)."
    else
      human "Note whether a 'Background Items Added' notice appeared (expected once, for the new LaunchDaemon). Then shut the VM down: it is the fresh-track base each later test clones (docs/vm-release-gate.md)."
    fi
    result
    ;;

  g2)
    # Constraint enforcement: launchd refuses every program but the
    # Developer ID one with the authority identifier.
    rig_on_a
    legacy="$(unpack legacy)/Micropod.app/Contents/Helpers"
    legacy="$legacy/Micropod Runtime Setup.app/Contents/MacOS/MicropodRuntimeHost"
    adhoc="$GATE/adhoc-helper"
    cp "$PROGRAM" "$adhoc"
    codesign --force -s - -i com.skunkworq.micropod.runtime-authority "$adhoc" >/dev/null 2>&1
    variant ad-hoc "$adhoc"
    variant legacy-identifier "$legacy"
    variant cli-identifier "$(unpack A)/micropod"
    other=$(find "$RC/other-team" -maxdepth 1 -type f 2>/dev/null | head -1)
    if [ -n "$other" ]; then variant other-team "$other"
    else say "  SKIP  other-team: put another team's Developer ID binary in $RC/other-team"; fi
    dev=$(find "$RC/apple-development" -maxdepth 1 -type f 2>/dev/null | head -1)
    if [ -n "$dev" ]; then variant apple-development "$dev"
    else say "  SKIP  apple-development: put an Apple Development-signed helper in $RC/apple-development"; fi
    finished A
    [ -n "$other" ] && [ -n "$dev" ] || { [ "$FAILED" -eq 0 ] && result INCOMPLETE; }
    result
    ;;

  g3-kill)
    # One case of the migration kill matrix (gate-host.sh runs them all on
    # clones of the legacy VM): install-authority dies at $2.
    point=${2:?checkpoint: $CHECKPOINTS}
    rig_needs legacy
    # On a rig the one kill comes after the live 0.13.3 helper handed over.
    [ -z "$RIG" ] || [ "$point" = retired ] || die "on a rig the one kill is at retired"
    install_authority A "$point"
    status=$?
    sudo rm -f "$RH/gate-kill.json"
    if [ "$status" -eq 0 ] && [ "$point" = started ]; then
      # The authority already served when the legacy job was retired.
      say "  INFO  started not reached: nothing was left to start"
    else
      check "install-authority died at $point (status $status)" test "$status" -eq 137
    fi
    check "at most one helper process" at_most_one_helper
    # On a rig there is one 0.13.3 install, so its one kill reboots too;
    # a kill that failed does not reboot the rig for nothing.
    [ -z "$RIG" ] || [ "$FAILED" -ne 0 ] || needs_reboot "g3-check $point rebooted"
    result
    ;;

  g3-check)
    # After a kill ($2) and, with "rebooted" ($3), a reboot: the invariants,
    # then a re-run finishes the migration.
    point=${2:?checkpoint}
    rig_needs legacy
    [ "${3:-}" != rebooted ] || rig_after_reboot
    sudo rm -f "$RH/gate-kill.json"
    check "at most one helper process" at_most_one_helper
    if [ "${3:-}" = rebooted ] && [ "$point" != staged ]; then
      # Neutralized before the reboot: no launch runs 0.13.3 code again.
      check "no 0.13.3 code runs as root after the reboot" no_identifier "$LEGACY_LABEL"
    fi
    check "the re-run of install-authority finishes" install_authority A
    finished A
    check "no 0.13.3 code runs as root" no_identifier "$LEGACY_LABEL"
    result
    ;;

  g4-before)
    # Baseline on the legacy VM before migrating: can an admin-group process
    # (run as a LaunchAgent child) get its own code run as root?
    plant_residual
    planted=$?
    if [ "$planted" -eq 2 ]; then
      incomplete "the agent-spawned planter never started: no baseline"
    else
      check "the residual was planted by an agent-spawned process" test "$planted" -eq 0
      child_checks
    fi
    needs_reboot g4-before-after
    ;;
  g4-before-after)
    if [ -f "$GATE/residual" ] && [ ! -L "$GATE/residual" ] && [ "$(head -c 16 "$GATE/residual")" = 0 ]; then
      say "  INFO  baseline reproduced: the planted program ran as root"
    else
      say "  INFO  baseline not reproduced: nothing ran as root"
    fi
    say "  INFO  this clone is spent; delete it (docs/vm-release-gate.md)"
    result BASELINE
    ;;

  g4-after)
    # On a migrated VM (after g9): the same attack and a legacy Mach lookup
    # from an agent-spawned process must all fail, before and after a reboot.
    rig_needs legacy
    check "the legacy bundle is immutable (schg)" legacy_immutable
    as_agent_child "$(attacker_script)"
    ran=$?
    # A successful attempt fails the test whatever else happened.
    check "no attempt by the agent-spawned process succeeded" attack_clean
    if [ "$ran" -eq 2 ]; then
      incomplete "the agent-spawned attacker never started: nothing was attempted"
    else
      child_checks
      check "the attacker made its attempts (it created attack.out)" child_output "$GATE/attack.out"
    fi
    plant_residual
    planted=$?
    check "planting the residual fails" test "$planted" -ne 0
    if [ "$planted" -eq 2 ]; then
      incomplete "the agent-spawned planter never started: nothing was attempted"
    elif [ "$planted" -eq 1 ]; then
      child_checks
    fi
    user_cli legacy --json runtime operation >/dev/null 2>&1
    sleep 5
    check "a legacy-service lookup starts no legacy job" refuse legacy_loaded
    if [ -n "$RIG" ] && [ "$FAILED" -ne 0 ]; then
      # Something got through: undo it, and keep the rig up for a look.
      rig_undo_attack
      result
    fi
    rig_undo_attack
    needs_reboot g4-after-reboot
    ;;
  g4-after-reboot)
    rig_needs legacy
    rig_after_reboot
    check "nothing planted ran as root" refuse present "$GATE/residual"
    finished A
    check "the legacy bundle is still immutable" legacy_immutable
    result
    ;;

  g5)
    # Authority files under admin-group attack, from an agent-spawned process.
    rig_on_a
    before=$(sudo shasum -a 256 "$PLIST" "$PROGRAM")
    as_agent_child "$(attacker_script)"
    ran=$?
    # A successful attempt fails the test whatever else happened.
    check "no attempt succeeded" attack_clean
    if [ "$ran" -eq 2 ]; then
      incomplete "the agent-spawned attacker never started: nothing was attempted"
    else
      child_checks
      check "the attacker made its attempts (it created attack.out)" child_output "$GATE/attack.out"
    fi
    check "plist and program bytes are unchanged" \
      test "$(sudo shasum -a 256 "$PLIST" "$PROGRAM")" = "$before"
    rig_undo_attack
    finished A
    result
    ;;

  g6)
    # Self-update A -> B under the drain: no Login Items or BTM prompt.
    rig_on_a to-b
    va=$(version_of "$(unpack A)/Micropod.app")
    vb=$(version_of "$(unpack B)/Micropod.app")
    btm() { sudo sfltool dumpbtm 2>/dev/null | grep -ciE 'skunkworq|micropod'; }
    nb=$(btm)
    plist_before=$(shasum -a 256 "$PLIST")
    desktop B
    check "micropod runtime update starts" user_cli B runtime update --detach
    check "the update completes" poll_component B 'completed|helperUpdated'
    check "the update went from $va" test "$(status_field B componentUpdate.sourceVersion)" = "$va"
    check "the authority serves $vb" wait_serving "$vb"
    check "the LaunchDaemon plist is unchanged" \
      test "$(shasum -a 256 "$PLIST")" = "$plist_before"
    check "no new background item was registered" test "$(btm)" = "$nb"
    human "Did macOS show any Login Items, Background Items or administrator prompt during the update? If it did, note it; the next check asks."
    read -r -p ">>> Any prompt or notice appeared? [y/N] " answer
    check "no prompt or notice appeared" test "${answer:-n}" != y
    finished B
    result
    ;;

  g7-crash | g7-hang)
    # B crashes (or hangs) after its launch is counted: the helper rolls back
    # to A after three launches (a hang ends at the 120-second watchdog).
    fault=${STEP#g7-}
    rig_on_a to-b
    va=$(version_of "$(unpack A)/Micropod.app")
    vb=$(version_of "$(unpack B)/Micropod.app")
    gate_fault B "$fault"
    check "status reports the armed fault" \
      test "$(status_field A gateFaultArmed)" = true
    desktop B
    check "micropod runtime update starts" user_cli B runtime update --detach
    limit=600
    [ "$fault" = hang ] && limit=1500
    check "the update rolls back" poll_component B rolledBack "$limit"
    gate_fault off
    check "the authority serves $va again" wait_serving "$va" 180
    finished A
    result
    ;;

  g7-floor)
    # B carries a signed security floor of B: nothing goes below it.
    rig_on_a to-b
    va=$(version_of "$(unpack A)/Micropod.app")
    manifest="$(unpack B)/Micropod.app/Contents/Resources/runtime-components.json"
    floor=$(plutil -extract securityFloor raw -o - "$manifest" 2>/dev/null)
    vb=$(version_of "$(unpack B)/Micropod.app")
    if [ "$floor" != "$vb" ]; then
      say "  SKIP  B has no security floor of $vb; build B with qualification_security_floor=$vb"
      result INCOMPLETE
    fi
    desktop B
    check "update to B" user_cli B runtime update --detach
    check "the update completes" poll_component B 'completed|helperUpdated'
    check "the update went from $va" test "$(status_field B componentUpdate.sourceVersion)" = "$va"
    check "rollback below the floor is refused" rollback_refused B
    check "install-authority with A is refused" refuse install_authority A
    check "the authority still serves $vb" wait_serving "$vb"
    result
    ;;

  g8)
    # Sealed copies: what root installs carries no ACL, xattr, flag or
    # setuid bit, even when the source app was tampered with.
    rig_on_a to-b
    va=$(version_of "$(unpack A)/Micropod.app")
    vb=$(version_of "$(unpack B)/Micropod.app")
    desktop B
    setup="/Applications/Micropod.app/Contents/Helpers/Micropod Runtime Setup.app"
    sudo chmod +a "everyone allow write" "$setup/Contents/Info.plist"
    sudo xattr -w dev.micropod.gate planted "$setup/Contents/Info.plist"
    sudo chmod u+s "$setup/Contents/MacOS/MicropodRuntimeHost"
    check "micropod runtime update starts" user_cli B runtime update --detach
    check "the update from the tampered app completes" \
      poll_component B 'completed|helperUpdated'
    check "the update went from $va (B was copied from the tampered app)" \
      test "$(status_field B componentUpdate.sourceVersion)" = "$va"
    cur="$RH/authority/current"
    acl() { sudo ls -leR "$cur" | grep -q '^ [0-9]*: '; }
    xattrs() { [ -n "$(sudo xattr -lr "$cur")" ]; }
    loose() {
      [ -n "$(sudo find "$cur" \( -perm -4000 -o -perm -2000 -o -perm -g+w \
        -o -perm -o+w -o ! -user root -o ! -group wheel \) -print)" ]
    }
    check "no ACL in the installed authority" refuse acl
    check "no extended attribute" refuse xattrs
    check "no setuid/setgid, group/other write or other owner" refuse loose
    check "no file flags" refuse any_flags "$cur"
    check "the installed authority verifies strictly" \
      sudo codesign --verify --strict --deep "$cur/Micropod Runtime Setup.app"
    check "the authority serves $vb" wait_serving "$vb"
    finished B
    result
    ;;

  prepare-legacy)
    # The Gamma-128 starting point: 0.13.3 with its SMAppService helper.
    desktop legacy
    open /Applications/Micropod.app
    human "In Micropod, open Micropod Runtime Setup and click Install Dedicated Runtime. Approve 'Micropod Runtime Setup' in System Settings > General > Login Items & Extensions when asked, and wait until Setup says the runtime is installed."
    check "the legacy helper serves" legacy_loaded
    check "no authority plist yet" test ! -e "$PLIST"
    check "the gate records the runtime it created" allow_identity
    human "Shut the VM down and clone it as gate-legacy-base on the host (docs/vm-release-gate.md)."
    result
    ;;

  harden)
    # First step in a fresh base VM (vm_guard fresh ran): the marker, a
    # random password, key-only ssh, and with "matrix" a sudo rule that lets
    # the host run exactly the matrix steps.
    [ "$(id -u)" != 0 ] || die "run as the VM's admin user"
    key="$RC/gate_key.pub"
    [ -f "$key" ] || die "no $key: run 'bash gate-host.sh key' on the host first"
    grep -Eq '^ssh-ed25519 [A-Za-z0-9+/=]+( .*)?$' "$key" || die "$key is not an ed25519 public key"
    say "Password: the vanilla image's is 'admin'."
    read -r -s -p "Current password: " old
    say ""
    pw=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20)
    dscl . -passwd "/Users/$GATE_USER" "$old" "$pw" || die "the password was not changed (wrong current password?)"
    say "  PASS  random login password set"
    security set-keychain-password -o "$old" -p "$pw" >/dev/null 2>&1
    check "automatic login keeps working (the shared folder mounts at login)" \
      sudo sysadminctl -autologin set -userName "$GATE_USER" -password "$pw"
    say ""
    say ">>> The VM's password is now: $pw"
    say ">>> Write it down; sudo in this VM and its clones asks for it."
    mkdir -p "$HOME/.ssh" && chmod 0700 "$HOME/.ssh"
    cp "$key" "$HOME/.ssh/authorized_keys" && chmod 0600 "$HOME/.ssh/authorized_keys"
    conf=$(mktemp)
    printf '%s\n' "PasswordAuthentication no" "KbdInteractiveAuthentication no" \
      "PermitRootLogin no" "AuthenticationMethods publickey" >"$conf"
    sudo install -o root -g wheel -m 0644 "$conf" /etc/ssh/sshd_config.d/100-micropod-gate.conf
    rm -f "$conf"
    sudo launchctl kickstart -k system/com.openssh.sshd 2>/dev/null
    check "sshd accepts keys only" sh -c \
      "sudo sshd -T 2>/dev/null | grep -qx 'passwordauthentication no'"
    # Remove every passwordless sudo rule; the matrix gets its own, scoped.
    for f in /etc/sudoers.d/*; do
      [ -f "$f" ] && sudo grep -q NOPASSWD "$f" && sudo rm -f "$f"
    done
    check "no passwordless sudo rule is left in /etc/sudoers" \
      refuse sudo grep -q '^[^#]*NOPASSWD' /etc/sudoers
    if [ "${2:-}" = matrix ]; then
      sudo install -d -o root -g wheel -m 0755 "$(dirname "$ROOT_COPY")"
      sudo install -o root -g wheel -m 0755 "$0" "$ROOT_COPY"
      rule=$(mktemp)
      # The interpreter is named in the rule: nothing is looked up in PATH.
      {
        printf '%s ALL=(root) NOPASSWD: /bin/bash %s g3-kill *, ' "$GATE_USER" "$ROOT_COPY"
        printf '/bin/bash %s g3-check *, /sbin/shutdown -r now\n' "$ROOT_COPY"
      } >"$rule"
      check "the scoped matrix sudo rule is valid" sudo visudo -cf "$rule"
      sudo install -o root -g wheel -m 0440 "$rule" "$SUDOERS"
      rm -f "$rule"
      sudo -k
      check "sudo without a password runs the matrix steps" \
        sudo -n -l /bin/bash "$ROOT_COPY" g3-check staged
      check "sudo without a password does not run the copy any other way" \
        refuse sudo -n -l "$ROOT_COPY" g3-check staged
      check "sudo without a password runs nothing else" refuse sudo -n -l /usr/bin/true
    fi
    sudo -k
    check "sudo asks for the password again" refuse sudo -n true
    # The marker goes last: only a VM where every check above passed is a
    # gate VM (vm_guard requires the "hardened" line).
    if [ "$FAILED" -eq 0 ]; then
      marker=$(mktemp)
      printf 'micropod-gate-vm %s\nhardened %s\n' "$(uuidgen)" "$(date -u +%FT%TZ)" >"$marker"
      sudo install -o root -g wheel -m 0644 "$marker" "$MARKER"
      rm -f "$marker"
      check "the gate marker is written" grep -q '^hardened ' "$MARKER"
    else
      say "  harden failed: no marker was written; fix the failed check and run harden again"
    fi
    result
    ;;

  g9)
    # The administrator procedure on the legacy VM, exactly as documented.
    rig_needs legacy
    app="$(unpack A)/Micropod.app"
    r2=$(r2_cli) || r2=/nonexistent/micropod
    check "the R2 copy is A's signed CLI, owned by $GATE_USER and immutable" test "$r2" = "$R2_DIR/micropod"
    check "a user-owned CLI is refused as root (R2)" refuse sudo \
      "$r2" runtime install-authority --app "$app" --confirm x
    check "install-authority from the root-only copy" install_authority A
    finished A
    check "the legacy bundle is a sealed immutable copy" legacy_immutable
    check "no 0.13.3 code runs as root" no_identifier "$LEGACY_LABEL"
    desktop A
    check "micropod runtime update restarts the runtime onto A" \
      user_cli A runtime update --detach
    check "the runtime update settles" poll_component A 'completed|helperUpdated'
    human "Open Micropod Runtime Setup: 'Retire the Old Background Item...' must be offered. Click it and confirm."
    check "the old Login Items entry is gone" sh -c \
      "! sudo sfltool dumpbtm 2>/dev/null | grep -q '$LEGACY_LABEL'"
    if [ -n "$RIG" ]; then
      # g4-after runs next on the same boot and asks for the one reboot
      # g9-reboot checks after.
      rig_stamp
      printf '%s\n' g4-after >"$GATE/next"
      result
    fi
    needs_reboot g9-reboot
    ;;
  g9-reboot)
    rig_needs legacy
    rig_after_reboot
    finished A
    check "no 0.13.3 code runs as root after the reboot" no_identifier "$LEGACY_LABEL"
    result
    ;;

  rig-begin)
    # Rig mode's first step: which track this rig takes, and the root-owned
    # marker every later step requires. Again with the same run id, it only
    # prints the track.
    id=${2:-}
    [[ "$id" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "usage: rig-begin <run-id> (letters, digits, . _ -)"
    if sudo test -e "$RIG_MARKER" || sudo test -L "$RIG_MARKER"; then
      [ -f "$RIG_MARKER" ] && [ ! -L "$RIG_MARKER" ] && [ "$(stat -f %u "$RIG_MARKER")" = 0 ] ||
        die "$RIG_MARKER is not a root-owned file"
      first=$(head -1 "$RIG_MARKER")
      [ "$first" = "micropod-gate-rig $id" ] ||
        die "another gate run began on this rig ($first): finish it, or end it with 'rig-end' (cuttle micropod gate cleanup)"
      track=$(rig_track)
    else
      if [ -e "$PLIST" ]; then
        die "the runtime authority is already installed here ($PLIST): rig mode qualifies a rig's first authority install only"
      elif legacy_loaded; then
        # Exactly the 0.13.3 starting point: its helper serving, nothing
        # neutralized yet, and the legacy release's app installed.
        vl=$(version_of "$(unpack legacy)/Micropod.app") || die "no legacy release in $RC/legacy"
        [ -d "$LEGACY_APP" ] || die "the legacy job is loaded but $LEGACY_APP is missing"
        ! legacy_immutable || die "$LEGACY_APP is already sealed (schg): an earlier install-authority ran here"
        ! legacy_disabled || die "the legacy job is disabled: an earlier install-authority ran here"
        ! no_identifier "$LEGACY_LABEL" || die "no helper signed as $LEGACY_LABEL serves: start the 0.13.3 runtime first"
        [ "$(version_of /Applications/Micropod.app 2>/dev/null)" = "$vl" ] ||
          die "/Applications/Micropod.app is not $vl, the legacy release this track migrates from"
        track=legacy
      elif sudo test -e "$RH" || [ -e "$LEGACY_APP" ]; then
        die "Micropod runtime files exist ($RH or $LEGACY_APP) but no helper is installed: repair or remove them first"
      else
        track=fresh
      fi
      marker=$(mktemp)
      {
        printf 'micropod-gate-rig %s\n' "$id"
        printf 'track %s\n' "$track"
        printf 'began %s\n' "$(date -u +%FT%TZ)"
        if [ "$track" = legacy ]; then
          # The rig's own runtime is the one the legacy track migrates.
          instance=$(sudo plutil -extract instance raw -o - "$RH/identity.json" 2>/dev/null)
          [ -z "$instance" ] || printf 'identity %s\n' "$instance"
        fi
      } >"$marker"
      sudo install -o root -g wheel -m 0644 "$marker" "$RIG_MARKER"
      rm -f "$marker"
      sudo rm -rf "$RIG_DIR" "$SAVE_DIR"
      sudo chflags -R noschg "$R2_DIR" 2>/dev/null
      sudo rm -rf "$R2_DIR"
      sudo install -d -o root -g wheel -m 0700 "$RIG_DIR"
      # A new run starts with nothing of an old one: its results and its
      # extractions.
      if [ -e "$OUT/results.tsv" ] || [ -n "$(ls -A "$OUT/logs" 2>/dev/null)" ]; then
        old="$OUT/previous-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$old"
        mv "$OUT/results.tsv" "$old/" 2>/dev/null
        mv "$OUT/logs" "$old/" 2>/dev/null
        mkdir -p "$OUT/logs"
      fi
      rm -rf "$GATE"
      mkdir -m 0700 "$GATE" || die "cannot create $GATE"
      mkdir "$GATE/unpack" || die "cannot create $GATE/unpack"
    fi
    say "track $track"
    if fdesetup isactive >/dev/null 2>&1; then
      say "  INFO  FileVault is on: after each reboot, unlock this Mac at its own screen"
    fi
    check "the rig is marked for this run" grep -qx "micropod-gate-rig $id" "$RIG_MARKER"
    result
    ;;

  rig-save)
    # Fresh track, once, right after g1: root keeps A's high-water marks,
    # which rig-reset puts back after each test that moves the rig to B.
    rig_needs fresh
    ! sudo test -e "$RIG_DIR/component-state.json" || die "rig-save already ran for this run"
    va=$(version_of "$(unpack A)/Micropod.app")
    wait_serving "$va" 30 || die "A does not serve: g1 did not finish"
    state="$RH/component-state.json"
    check "the marks are A's (highest $va)" test "$(marks_field "$state" highestVersion)" = "$va"
    if [ "$FAILED" -eq 0 ]; then
      check "A's high-water marks are saved" sudo ditto --noextattr --noacl "$state" "$RIG_DIR/component-state.json"
    fi
    result
    ;;

  rig-reset)
    # After a test that moved the rig to B (whose floor is B): A's marks
    # back, A's app back, and the runtime rolled back to A. A real rig has
    # no clone to throw away; this is how it gets one back.
    rig_needs fresh
    va=$(version_of "$(unpack A)/Micropod.app")
    gate_fault off
    sudo rm -f "$RH/gate-kill.json"
    state="$RH/component-state.json"
    if ! sudo test -f "$RIG_DIR/component-state.json"; then
      check "rig-save ran" false
      result
    fi
    # shellcheck disable=SC2016 # $1 and $2 expand in root's shell
    check "A's high-water marks are put back" sudo sh -c \
      'ditto --noextattr --noacl "$1" "$2.gate" && mv -f "$2.gate" "$2"' _ "$RIG_DIR/component-state.json" "$state"
    check "A's app is installed again" desktop A
    if [ "$(serving_field version)" != "$va" ]; then
      check "micropod runtime update --rollback starts" user_cli A runtime update --rollback --detach
      check "the rollback settles as rolled back" poll_component A rolledBack
    fi
    check "the authority serves $va" wait_serving "$va" 180
    check "the marks are A's again" marks_match
    finished A
    # Only a reset that passed puts the rig back on A for the next test.
    if [ "$FAILED" -eq 0 ]; then sudo rm -f "$RIG_DIR/dirty"; fi
    result
    ;;

  rig-end)
    # The end of a rig run: the gate's own files go; the installed release
    # stays. Safe to run again, and without a marker. It refuses while a B
    # test is not undone: the saved marks are the only way back to A.
    if sudo test -e "$RIG_DIR/dirty"; then
      die "the rig is not back on A since $(sudo cat "$RIG_DIR/dirty"): run rig-reset first (A's saved marks are kept)"
    fi
    gate_fault off
    sudo rm -f "$RH/gate-kill.json"
    sudo chflags -R noschg "$R2_DIR" 2>/dev/null
    sudo rm -rf "$CHILD_BIN" "$RIG_DIR" "$SAVE_DIR" "$R2_DIR" /var/root/micropod-install
    sudo rm -f "$RIG_MARKER"
    rm -rf "$GATE"
    check "the rig marker is gone" refuse sudo test -e "$RIG_MARKER"
    result
    ;;

  report)
    column -t -s $'\t' "$OUT/results.tsv" 2>/dev/null || say "no results yet"
    ;;

  *)
    say "steps: harden [matrix], prepare-legacy, g1, g2, g3-kill <checkpoint>,"
    say "       g3-check <checkpoint> [rebooted], g4-before, g4-after, g5, g6,"
    say "       g7-crash, g7-hang, g7-floor, g8, g9, report"
    say "rig mode (MICROPOD_GATE_RIG=1): rig-begin <run-id>, rig-save, rig-reset, rig-end"
    say "       fresh track: g1 rig-save g2 g5 g7-crash rig-reset g7-hang rig-reset"
    say "                    g6 rig-reset g8 rig-reset g7-floor rig-reset"
    say "       legacy track: g3-kill retired (reboot) g3-check retired rebooted"
    say "                    g9 g4-after (reboot) g9-reboot g4-after-reboot"
    say "checkpoints: $CHECKPOINTS"
    ;;
esac
