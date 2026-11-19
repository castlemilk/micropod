#!/usr/bin/env bash
# Micropod runtime-authority release gate: runs INSIDE a throwaway macOS 26 VM
# (docs/vm-release-gate.md). Never run it on a real rig: it replaces, kills and
# attacks the runtime helper on purpose.
#
#   bash runtime-authority-gate.sh <step>      one step; prints PASS/FAIL lines
#   bash runtime-authority-gate.sh report      every result so far
#
# Release candidates come from the shared folder (tart --dir=rc:<host dir>):
#   $RC/A/Micropod.<A>.tgz        candidate A (the release under test)
#   $RC/B/Micropod.<B>.tgz        candidate B, newer than A (G6, G7)
#   $RC/legacy/Micropod.0.13.3.tgz   the SMAppService release to migrate from
#   $RC/other-team/<binary>       optional: any other team's Developer ID binary
#   $RC/apple-development/<bin>   optional: an Apple Development-signed helper
#
# Results: $OUT/results.tsv and $OUT/logs (the host's ~/micropod-gate-vm/out).
# Exit codes: 0 every check passed, 1 a check failed, 75 the step needs a
# reboot (reboot, log in, run the step it names).
set -u -o pipefail

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

# Results and logs go to the host's writable share when there is one, so
# they outlive a deleted clone.
OUT=${MICROPOD_GATE_OUT:-"/Volumes/My Shared Files/out"}
[ -d "$OUT" ] && [ -w "$OUT" ] || OUT=$GATE
mkdir -p "$GATE/unpack" "$OUT/logs"
STEP=${1:-help}
FAILED=0

say() { printf '%s\n' "$*"; }

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

result() {
  local verdict=PASS
  [ "$FAILED" -eq 0 ] || verdict=FAIL
  [ "${1:-}" = "" ] || verdict=$1
  printf '%s\t%s\t%s\n' "$(date '+%F %T')" "$STEP" "$verdict" >>"$OUT/results.tsv"
  say "== $STEP: $verdict"
  [ "$verdict" = FAIL ] && exit 1
  exit 0
}

human() {
  say ""
  say ">>> HUMAN STEP: $*"
  read -r -p ">>> Press Enter when done (Ctrl-C to stop) " _
}

needs_reboot() {
  printf '%s\n' "$1" >"$GATE/next"
  say ""
  say ">>> REBOOT: sudo shutdown -r now"
  say ">>> After logging in again: bash $0 $1"
  exit 75
}

# unpack <name>: $GATE/unpack/<name>/{Micropod.app,micropod}
unpack() {
  local dir="$GATE/unpack/$1" tgz
  tgz=$(find "$RC/$1" -maxdepth 1 -name 'Micropod.*.tgz' | head -1)
  [ -n "$tgz" ] || { say "missing $RC/$1/Micropod.*.tgz" >&2; exit 1; }
  if [ ! -d "$dir/Micropod.app" ]; then
    mkdir -p "$dir"
    tar -xzf "$tgz" -C "$dir" || exit 1
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
  src=$(unpack "$1")
  ver=$(version_of "$src/Micropod.app")
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

cdhash12() {
  local setup="$1/Contents/Helpers/Micropod Runtime Setup.app"
  codesign -dvvv "$setup" 2>&1 | sed -n 's/^CDHash=//p' | cut -c1-12
}

# install_authority <name> [VAR=value...]: the administrator procedure.
install_authority() {
  local name=$1 cli app
  shift
  cli=$(root_cli "$name") || return 1
  app="$(unpack "$name")/Micropod.app"
  sudo env "$@" "$cli" runtime install-authority --app "$app" \
    --confirm "$(cdhash12 "$app")"
}

user_cli() { "$(unpack "$1")/micropod" "${@:2}"; }

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
  sudo rm -rf /Applications/Micropod.app
  sudo ditto "$(unpack "$1")/Micropod.app" /Applications/Micropod.app
}

gate_fault() {
  local file="$RH/gate-fault.json"
  if [ -z "$2" ]; then sudo rm -f "$file"; return; fi
  printf '{"version":"%s","fault":"%s"}' "$1" "$2" |
    sudo tee "$file" >/dev/null
  sudo chown root:wheel "$file"
  sudo chmod 0600 "$file"
}

# as_agent_child <script>: run <script> as this user from a user LaunchAgent,
# the context a job the Cuttlefish agent spawns runs in.
as_agent_child() {
  local plist="$HOME/Library/LaunchAgents/dev.micropod.gate.child.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  rm -f "$GATE/child.done"
  plutil -create xml1 "$plist"
  plutil -insert Label -string dev.micropod.gate.child "$plist"
  plutil -insert ProgramArguments -array "$plist"
  plutil -insert ProgramArguments -string /bin/bash -append "$plist"
  plutil -insert ProgramArguments -string "$1" -append "$plist"
  plutil -insert RunAtLoad -bool true "$plist"
  launchctl bootstrap "gui/$(id -u)" "$plist"
  local i
  for ((i = 0; i < 60; i++)); do
    [ -f "$GATE/child.done" ] && break
    sleep 1
  done
  launchctl bootout "gui/$(id -u)/dev.micropod.gate.child" 2>/dev/null
  rm -f "$plist"
  [ -f "$GATE/child.done" ]
}

attacker_script() {
  # Each attempt appends "<name> ok" if it succeeded (it must not).
  local s="$GATE/attack.sh"
  {
    printf '%s\n' '#!/bin/bash'
    printf 'out=%q\n' "$GATE/attack.out"
    printf ': >"$out"\n'
    printf 'try() { n=$1; shift; "$@" 2>/dev/null && echo "$n ok" >>"$out"; }\n'
    printf 'try plist-write sh -c %q\n' "echo x >>'$PLIST'"
    printf 'try plist-move mv %q /tmp/p\n' "$PLIST"
    printf 'try plist-remove rm -f %q\n' "$PLIST"
    printf 'try program-write sh -c %q\n' "echo x >>'$PROGRAM'"
    printf 'try runtimehost-create touch %q\n' "$RH/authority/x"
    printf 'try runtimehost-acl chmod +a "everyone allow write" %q\n' "$RH"
    printf 'try support-move mv %q /tmp/m\n' "/Library/Application Support/Micropod"
    printf 'try bootout launchctl bootout system/%s\n' "$AUTH_LABEL"
    printf 'try disable launchctl disable system/%s\n' "$AUTH_LABEL"
    printf 'try kickstart launchctl kickstart -k system/%s\n' "$AUTH_LABEL"
    printf 'try legacy-move mv %q /tmp/l.app\n' "$LEGACY_APP"
    printf 'try legacy-write sh -c %q\n' \
      "echo x >>'$LEGACY_APP/Contents/MacOS/MicropodRuntimeHost'"
    printf 'try legacy-flags chflags -R noschg %q\n' "$LEGACY_APP"
    printf 'touch %q\n' "$GATE/child.done"
  } >"$s"
  printf '%s\n' "$s"
}

# plant_residual: the reviewer's residual as an admin-group process: move the
# legacy bundle aside and put an ad-hoc helper in its place.
plant_residual() {
  local s="$GATE/plant.sh" evil="$GATE/evil.sh"
  {
    printf '#!/bin/sh\nid -u >%q\nexec sleep 600\n' "$GATE/residual"
  } >"$evil"
  chmod 0755 "$evil"
  {
    printf '%s\n' '#!/bin/bash'
    printf 'app=%q\n' "$LEGACY_APP"
    printf 'mv "$app" %q && ditto %q "$app" &&\n' "$GATE/moved.app" "$GATE/moved.app"
    printf '  cp %q "$app/Contents/MacOS/MicropodRuntimeHost" &&\n' "$evil"
    printf '  echo planted >%q\n' "$GATE/planted"
    printf 'touch %q\n' "$GATE/child.done"
  } >"$s"
  rm -f "$GATE/planted" "$GATE/residual"
  as_agent_child "$s" && [ -f "$GATE/planted" ]
}

# variant <name> <binary>: launchd must refuse to spawn the authority job
# with <binary> as its program, and the original must serve again after.
variant() {
  local name=$1 bin=$2 saved="$GATE/program.saved" ver pid_before
  ver=$(serving_field version)
  pid_before=$(serving_field pid)
  # Renamed into place, never written over the running executable.
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
    # Fresh install on a VM that never had Micropod.
    app="$(unpack A)/Micropod.app"
    check "Gatekeeper accepts Micropod.app (notarized Developer ID)" \
      spctl -a -t exec "$app"
    check "a user-owned CLI is refused as root (R2)" refuse sudo \
      "$(unpack A)/micropod" runtime install-authority --app "$app" --confirm x
    check "nothing was installed by the refused run" test ! -e "$PLIST"
    check "install-authority from the root-only copy" install_authority A
    finished A
    desktop A
    check "the dedicated runtime installs" user_cli A runtime install
    check "the install settles" poll_operation A
    human "Note whether a 'Background Items Added' notice appeared (expected once, for the new LaunchDaemon). Then shut the VM down and clone it as gate-fresh-a on the host (docs/vm-release-gate.md)."
    result
    ;;

  g2)
    # Constraint enforcement: launchd refuses every program but the
    # Developer ID one with the authority identifier.
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
    install_authority A MICROPOD_GATE_KILL_AT="$point"
    status=$?
    if [ "$status" -eq 0 ] && [ "$point" = started ]; then
      # The authority already served when the legacy job was retired.
      say "  INFO  started not reached: nothing was left to start"
    else
      check "install-authority died at $point (status $status)" test "$status" -eq 137
    fi
    check "at most one helper process" at_most_one_helper
    result
    ;;

  g3-check)
    # After a kill ($2) and, with "rebooted" ($3), a reboot: the invariants,
    # then a re-run finishes the migration.
    point=${2:?checkpoint}
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
    check "the residual was planted by an agent-spawned process" plant_residual
    needs_reboot g4-before-after
    ;;
  g4-before-after)
    if [ "$(cat "$GATE/residual" 2>/dev/null)" = 0 ]; then
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
    check "the legacy bundle is immutable (schg)" legacy_immutable
    as_agent_child "$(attacker_script)"
    check "no attempt by the agent-spawned process succeeded" \
      test ! -s "$GATE/attack.out"
    check "planting the residual fails" refuse plant_residual
    user_cli legacy --json runtime operation >/dev/null 2>&1
    sleep 5
    check "a legacy-service lookup starts no legacy job" refuse legacy_loaded
    needs_reboot g4-after-reboot
    ;;
  g4-after-reboot)
    check "nothing planted ran as root" test ! -e "$GATE/residual"
    finished A
    check "the legacy bundle is still immutable" legacy_immutable
    result
    ;;

  g5)
    # Authority files under admin-group attack, from an agent-spawned process.
    before=$(sudo shasum -a 256 "$PLIST" "$PROGRAM")
    as_agent_child "$(attacker_script)"
    check "no attempt succeeded" test ! -s "$GATE/attack.out"
    check "plist and program bytes are unchanged" \
      test "$(sudo shasum -a 256 "$PLIST" "$PROGRAM")" = "$before"
    finished A
    result
    ;;

  g6)
    # Self-update A -> B under the drain: no Login Items or BTM prompt.
    vb=$(version_of "$(unpack B)/Micropod.app")
    btm() { sudo sfltool dumpbtm 2>/dev/null | grep -ciE 'skunkworq|micropod'; }
    nb=$(btm)
    plist_before=$(shasum -a 256 "$PLIST")
    desktop B
    check "micropod runtime update starts" user_cli B runtime update --detach
    check "the update completes" poll_component B 'completed|helperUpdated'
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
    va=$(version_of "$(unpack A)/Micropod.app")
    vb=$(version_of "$(unpack B)/Micropod.app")
    gate_fault "$vb" "$fault"
    desktop B
    check "micropod runtime update starts" user_cli B runtime update --detach
    limit=600
    [ "$fault" = hang ] && limit=1500
    check "the update rolls back" poll_component B rolledBack "$limit"
    gate_fault "" ""
    check "the authority serves $va again" wait_serving "$va" 180
    finished A
    result
    ;;

  g7-floor)
    # B carries a signed security floor of B: nothing goes below it.
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
    check "rollback below the floor is refused" rollback_refused B
    check "install-authority with A is refused" refuse install_authority A
    check "the authority still serves $vb" wait_serving "$vb"
    result
    ;;

  g8)
    # Sealed copies: what root installs carries no ACL, xattr, flag or
    # setuid bit, even when the source app was tampered with.
    vb=$(version_of "$(unpack B)/Micropod.app")
    desktop B
    setup="/Applications/Micropod.app/Contents/Helpers/Micropod Runtime Setup.app"
    sudo chmod +a "everyone allow write" "$setup/Contents/Info.plist"
    sudo xattr -w dev.micropod.gate planted "$setup/Contents/Info.plist"
    sudo chmod u+s "$setup/Contents/MacOS/MicropodRuntimeHost"
    check "micropod runtime update starts" user_cli B runtime update --detach
    check "the update from the tampered app completes" \
      poll_component B 'completed|helperUpdated'
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
    human "Shut the VM down and clone it as gate-legacy-base on the host (docs/vm-release-gate.md)."
    result
    ;;

  g9)
    # The administrator procedure on the legacy VM, exactly as documented.
    app="$(unpack A)/Micropod.app"
    check "a user-owned CLI is refused as root (R2)" refuse sudo \
      "$(unpack A)/micropod" runtime install-authority --app "$app" --confirm x
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
    needs_reboot g9-reboot
    ;;
  g9-reboot)
    finished A
    check "no 0.13.3 code runs as root after the reboot" no_identifier "$LEGACY_LABEL"
    result
    ;;

  report)
    column -t -s $'\t' "$OUT/results.tsv" 2>/dev/null || say "no results yet"
    ;;

  *)
    say "steps: prepare-legacy g1 g2 g3-kill <checkpoint> g3-check g4-before"
    say "       g4-after g5 g6 g7-crash g7-hang g7-floor g8 g9 report"
    say "checkpoints: $CHECKPOINTS"
    ;;
esac
