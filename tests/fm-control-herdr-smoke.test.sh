#!/usr/bin/env bash
# tests/fm-control-herdr-smoke.test.sh - real-herdr smoke test for the agent
# lifecycle control plane (bin/fm-control.sh).
#
# tmux is the control plane's reference backend and is covered hermetically in
# tests/fm-control.test.sh. herdr is the OTHER backend whose recovery-grade
# agent-state classifier the control plane is allowed to trust, so its
# behavior is pinned here against the REAL binary rather than a stub: whether
# an agent is running, and therefore whether a lifecycle verb may act at all,
# comes from herdr's own agent registry.
#
# No real harness is launched. herdr's `pane report-agent` is the same registry
# the adapter reads, and a symlink named like a harness is the same process
# identity the adapter proves through `pane process-info`, so registering an
# agent over a real agent-named process, over a plain shell, and not at all
# exercises exactly the classification the control plane gates on - including
# the registration Herdr keeps after the agent process is gone (issue #4115).
#
# Always runs through bin/fm-herdr-lab.sh on a private, named, throwaway
# session, never the default one. Skips cleanly when herdr or jq is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || { printf 'not ok - Herdr lab helper is not executable: %s\n' "$HERDR_LAB_HELPER" >&2; exit 1; }
SESSION=$("$HERDR_LAB_HELPER" name fm-control-smoke) || { echo "not ok - could not generate isolated Herdr lab session name" >&2; exit 1; }
unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID
export HERDR_SESSION="$SESSION"
SCRATCH=
LAB_OWNED=0
cleanup_all() {
  local status=$? teardown_status=0
  trap - EXIT
  if [ "$LAB_OWNED" = 1 ]; then
    LAB_OWNED=0
    "$HERDR_LAB_HELPER" teardown "$SESSION" || teardown_status=$?
  fi
  [ -z "$SCRATCH" ] || rm -rf "$SCRATCH"
  [ "$status" -ne 0 ] || status=$teardown_status
  exit "$status"
}
trap cleanup_all EXIT
LAB_OWNED=1
"$HERDR_LAB_HELPER" provision "$SESSION" || fail "could not provision isolated Herdr lab session"
lab() { "$HERDR_LAB_HELPER" run "$SESSION" "$@"; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsmoke"
cat > "$HOME_DIR/data/hsmoke/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Herdr lifecycle control safely.

## Firstmate spec
Keep the isolated endpoint and worktree intact.
EOF

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsmoke "$WT"
PROJ_REAL=$(cd "$PROJ" && pwd -P)
WT_REAL=$(cd "$WT" && pwd -P)

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hsmoke"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/hsmoke.meta"

run_control() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# --- no registered agent: the endpoint exists but hosts no agent ------------

OUT=$(run_control hsmoke exit) || fail "exit against an agent-free herdr pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "an agent-free herdr pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a pane with no registered agent is idempotent success"

# --- the recovery-grade read, against the real binary ------------------------
#
# The classification that decides whether a task can be recovered at all is read
# out of what herdr actually answers, so a stub can only confirm the assumption
# already written into the stub. Its logic is pinned portably in
# tests/fm-backend-herdr.test.sh; this is the check that notices when the real
# client stops answering the way that logic expects, and it names the version so
# a release change is attributed rather than mysterious.
HERDR_VERSION=$(lab status --json 2>/dev/null | jq -r '.client.version // "unknown"')
version_fail() {  # <message>
  fail "$1 [herdr $HERDR_VERSION]"
}

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = dead ] \
  || version_fail "a real, present, agent-free pane reads '$STATE' rather than 'dead'; every relaunch would be refused"

# `status --json` is the second signal, and the only one that answers for a
# session whose operational calls cannot be reached at all. A release that drops
# or renames `.server.running` would silently make every gone endpoint
# unrecoverable again, so it is asserted by name on both a live and an absent
# session.
[ "$(fm_backend_herdr_server_running_state "$SESSION")" = running ] \
  || version_fail "this run's own live lab session does not report .server.running=true through status --json"
[ "$(fm_backend_herdr_server_running_state "fm-lab-never-started-$$")" = stopped ] \
  || version_fail "a session with no server does not report .server.running=false, so authoritative absence can no longer be told from an unreadable read"

# Issue #4091's exact stranding shape: an endpoint recorded in a session whose
# server is not running used to read `unreadable` and block recovery.
[ "$(fm_backend_agent_state herdr "fm-lab-never-started-$$:w1:p2")" = missing ] \
  || version_fail "an endpoint in a session with no running server is not classified as recoverable"

# And the safety direction: an uninterpretable read must never license recovery.
[ "$(fm_backend_agent_state herdr "no-separator-here")" = unreadable ] \
  || version_fail "a malformed endpoint target does not stay unreadable"
pass "real herdr $HERDR_VERSION: a gone session reads recoverable while a live pane and a malformed target do not"

FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/codex" <<EOF
#!/usr/bin/env bash
: > "$SCRATCH/codex-launched"
EOF
chmod +x "$FAKEBIN/codex"
printf -v FAKEBIN_Q '%q' "$FAKEBIN"
printf -v PROJ_Q '%q' "$PROJ"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "export PATH=$FAKEBIN_Q:\$PATH" \
  || fail "could not put the inert test harness on the pane PATH"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "cd -- $PROJ_Q" \
  || fail "could not move the agent-free pane out of its recorded worktree"
for _ in $(seq 1 20); do
  [ "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)" != "$PROJ_REAL" ] || break
  sleep 0.1
done
[ "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)" = "$PROJ_REAL" ] \
  || fail "the real Herdr pane did not drift out of its recorded worktree"

OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" hsmoke --relaunch --harness codex) \
  || fail "a drifted, agent-free Herdr pane should be re-homed and relaunched: $OUT"
for _ in $(seq 1 20); do
  [ ! -e "$SCRATCH/codex-launched" ] || break
  sleep 0.1
done
[ -e "$SCRATCH/codex-launched" ] || fail "the replacement harness was not launched"
for _ in $(seq 1 20); do
  [ "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)" != "$WT_REAL" ] || break
  sleep 0.1
done
[ "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)" = "$WT_REAL" ] \
  || fail "the relaunched Herdr shell did not end up in its recorded worktree"
[ "$(sed -n 's/^window=//p' "$HOME_DIR/state/hsmoke.meta" | tail -1)" = "$SESSION:$PANE_ID" ] \
  || fail "the Herdr relaunch replaced its endpoint instead of reusing it"
lab pane get "$PANE_ID" >/dev/null 2>&1 \
  || fail "the Herdr relaunch removed the endpoint it was required to reuse"
awk -F= '$1 == "harness" {$0="harness=claude"} {print}' "$HOME_DIR/state/hsmoke.meta" \
  > "$HOME_DIR/state/hsmoke.meta.tmp"
mv "$HOME_DIR/state/hsmoke.meta.tmp" "$HOME_DIR/state/hsmoke.meta"
pass "real herdr: a drifted agent-free shell returns to its worktree and reuses the same endpoint"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse when herdr reports no agent on the pane: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses when herdr's own agent registry reports no agent"

# --- an agent-free endpoint drifted outside its recorded worktree -----------

REROOT_ID=hreroot
REROOT_WT="$SCRATCH/wt space; touch HERDR_INJECTED; quote ' \$(touch HERDR_SUBSTITUTED)"
git -C "$PROJ" worktree add --quiet -b hreroot "$REROOT_WT"
mkdir -p "$HOME_DIR/data/$REROOT_ID"
cat > "$HOME_DIR/data/$REROOT_ID/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise injection-resistant Herdr cwd recovery.

## Firstmate spec
Relaunch in the exact recorded worktree without executing path text.
EOF
REROOT_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-$REROOT_ID" "$PROJ" "") \
  || fail "could not create drifted-cwd relaunch pane"
read -r REROOT_TAB_ID REROOT_PANE_ID <<EOF
$REROOT_IDS
EOF
[ -n "$REROOT_TAB_ID" ] && [ -n "$REROOT_PANE_ID" ] || fail "drifted-cwd pane returned incomplete ids"
{
  echo "window=$SESSION:$REROOT_PANE_ID"
  echo "endpoint_task_id=$REROOT_ID"
  echo "worktree=$REROOT_WT"
  echo "project=$PROJ"
  echo "harness=pi"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$REROOT_TAB_ID"
  echo "herdr_pane_id=$REROOT_PANE_ID"
} > "$HOME_DIR/state/$REROOT_ID.meta"
REROOT_MARKER="$SCRATCH/reroot-launch-cwd"
OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" "$REROOT_ID" --relaunch --harness "pwd > '$REROOT_MARKER'" 2>&1) \
  || fail "agent-free Herdr cwd recovery should launch: $OUT"
i=0
while [ ! -s "$REROOT_MARKER" ] && [ "$i" -lt 50 ]; do
  sleep 0.1
  i=$((i + 1))
done
[ -s "$REROOT_MARKER" ] || fail "replacement command did not execute after Herdr cwd recovery"
REROOT_EXPECTED=$(cd "$REROOT_WT" && pwd -P)
REROOT_LAUNCHED=$(cd "$(cat "$REROOT_MARKER")" && pwd -P)
[ "$REROOT_LAUNCHED" = "$REROOT_EXPECTED" ] \
  || fail "replacement command ran in '$REROOT_LAUNCHED', not '$REROOT_EXPECTED'"
REROOT_LIVE=$("$HERDR_LAB_HELPER" run "$SESSION" pane get "$REROOT_PANE_ID" \
  | jq -r '.result.pane.foreground_cwd // empty')
REROOT_LIVE=$(cd "$REROOT_LIVE" && pwd -P)
[ "$REROOT_LIVE" = "$REROOT_EXPECTED" ] || fail "exact Herdr endpoint did not retain the recovered cwd"
[ ! -e "$PROJ/HERDR_INJECTED" ] || fail "semicolon-bearing worktree path executed shell text"
[ ! -e "$PROJ/HERDR_SUBSTITUTED" ] || fail "worktree path executed command substitution"
pass "real herdr: an exact agent-free endpoint safely re-roots to an injection-resistant recorded worktree before replacement launch"

# --- no registration but a live foreground command: refuse every input ------
#
# Registration absence is not shell-idleness proof. This is the counterexample
# to upstream's simpler recovery path: a drifted pane with sleep in the
# foreground still classifies recoverable at the registration layer, but it
# must receive neither a reroot command nor replacement-launch input.
BUSY_ID=hbusy
BUSY_WT="$SCRATCH/busy-wt"
git -C "$PROJ" worktree add --quiet -b hbusy "$BUSY_WT"
mkdir -p "$HOME_DIR/data/$BUSY_ID"
cat > "$HOME_DIR/data/$BUSY_ID/brief.md" <<'EOF'
# Task
## Captain's intent
Refuse relaunch input while an unregistered foreground command is still busy.

## Firstmate spec
Preserve the exact endpoint and isolated worktree.
EOF
BUSY_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-$BUSY_ID" "$PROJ" "") \
  || fail "could not create busy no-registration relaunch pane"
read -r BUSY_TAB_ID BUSY_PANE_ID <<EOF
$BUSY_IDS
EOF
[ -n "$BUSY_TAB_ID" ] && [ -n "$BUSY_PANE_ID" ] || fail "busy relaunch pane returned incomplete ids"
{
  echo "window=$SESSION:$BUSY_PANE_ID"
  echo "endpoint_task_id=$BUSY_ID"
  echo "worktree=$BUSY_WT"
  echo "project=$PROJ"
  echo "harness=pi"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$BUSY_TAB_ID"
  echo "herdr_pane_id=$BUSY_PANE_ID"
} > "$HOME_DIR/state/$BUSY_ID.meta"
lab pane run "$BUSY_PANE_ID" "sleep 900" >/dev/null 2>&1 \
  || fail "could not start the unregistered foreground command"
BUSY_PID=
for _ in $(seq 1 50); do
  BUSY_PID=$(lab pane process-info --pane "$BUSY_PANE_ID" 2>/dev/null \
    | jq -r '.result.process_info.foreground_processes[]? | select(.name == "sleep") | .pid' | head -1)
  [ -z "$BUSY_PID" ] || break
  sleep 0.1
done
[ -n "$BUSY_PID" ] || version_fail "the unregistered sleep command never became the pane foreground"
[ "$(fm_backend_agent_state herdr "$SESSION:$BUSY_PANE_ID")" = dead ] \
  || fail "the busy no-registration counterexample did not reach the recoverable registration verdict"
BUSY_MARKER="$SCRATCH/busy-launch-marker"
if OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" "$BUSY_ID" --relaunch --harness "touch '$BUSY_MARKER'" 2>&1); then
  fail "an unregistered endpoint with a foreground non-shell process accepted relaunch input: $OUT"
fi
case "$OUT" in
  *"not one provably idle shell"*) : ;;
  *) fail "the busy no-registration refusal did not identify the missing idle-shell proof: $OUT" ;;
esac
[ ! -e "$BUSY_MARKER" ] || fail "a busy unregistered endpoint received replacement-launch input"
BUSY_AFTER=$(lab pane process-info --pane "$BUSY_PANE_ID" 2>/dev/null \
  | jq -r '.result.process_info.foreground_processes[]? | select(.name == "sleep") | .pid' | head -1)
[ "$BUSY_AFTER" = "$BUSY_PID" ] \
  || fail "the busy unregistered endpoint received reroot or other shell input before refusal"
lab pane send-keys "$BUSY_PANE_ID" ctrl+c >/dev/null 2>&1 || true
pass "real herdr: an unregistered endpoint with a foreground non-shell process receives no reroot or replacement-launch input"

# --- a registered agent WITH a live process: classification flips ------------
#
# A registration alone no longer proves an agent (issue #4115): the adapter
# verifies the pane's processes through the real `pane process-info` view. So
# the registered agent is backed by a real agent-named foreground process - a
# symlink to a long-running system binary named `claude`, the same construction
# tests/fm-tmux-agent-liveness.test.sh uses (a copied platform binary fails code
# signing on macOS arm64; the symlink name is what the kernel records as argv[0]).
AGENT_BIN="$SCRATCH/agentbin"
mkdir -p "$AGENT_BIN"
SLEEP_BIN=$(command -v sleep) || fail "sleep not found"
ln -s "$SLEEP_BIN" "$AGENT_BIN/claude"
printf -v AGENT_Q '%q' "$AGENT_BIN/claude"

wait_process_state() {  # <expected> <tries>
  local expected=$1 tries=$2 i=0
  while [ "$i" -lt "$tries" ]; do
    [ "$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")" != "$expected" ] || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_relaunch_shell_settled() {
  local previous='' current='' i=0
  while [ "$i" -lt 50 ]; do
    current=$(fm_backend_herdr_pane_relaunch_shell_pid "$SESSION" "$PANE_ID" 2>/dev/null || true)
    if [ -n "$current" ] && [ "$current" = "$previous" ]; then
      return 0
    fi
    previous=$current
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

start_agent_process() {
  fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "$AGENT_Q 900" \
    || fail "could not start the agent-named foreground process in the task pane"
  wait_process_state agent 50 \
    || version_fail "a real agent-named foreground process reads '$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")' rather than 'agent' through pane process-info"
}

start_agent_process
"$HERDR_LAB_HELPER" run "$SESSION" pane report-agent "$PANE_ID" \
  --source fm-control-smoke --agent fm-control-smoke-agent --state idle >/dev/null 2>&1 \
  || fail "could not register a live agent on the task pane"

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = alive ] || fail "herdr should classify a registered agent with a live process as alive, got '$STATE'"

OUT=$(run_control hsmoke interrupt) || fail "interrupt against a registered agent should succeed: $OUT"
case "$OUT" in
  *"interrupt-delivered hsmoke harness=claude backend=herdr verified=agent-alive cancel=unconfirmed"*) : ;;
  *) fail "interrupt should report the agent-alive proof on herdr, got: $OUT" ;;
esac
pass "real herdr: interrupt delivers the harness's key and proves the agent survived it"

"$HERDR_LAB_HELPER" run "$SESSION" pane get "$PANE_ID" >/dev/null 2>&1 \
  || fail "the control plane must never remove the endpoint it was operating on"
[ -d "$WT" ] || fail "the control plane must never remove the task's local copy"
pass "real herdr: no control verb removed the endpoint or the task's local copy"

# --- the stale registration (issue #4115): the agent process is gone, the ---
# --- record is not, and recovery must proceed anyway ------------------------
#
# Stopping the agent-named process leaves the pane a plain shell while Herdr
# keeps the registration, which is exactly the shape a Pi crew leaves behind
# when it exits under a nested shell. Before the fix this read `alive` forever:
# exit waited out its timeout and refused, and relaunch was refused for good.
AGENT_PID=$(lab pane process-info --pane "$PANE_ID" 2>/dev/null \
  | jq -r '.result.process_info.foreground_processes[0].pid // empty')
[ -n "$AGENT_PID" ] || fail "could not read the agent-named process pid from pane process-info"
kill "$AGENT_PID" 2>/dev/null || fail "could not stop the agent-named process"
wait_process_state shell 50 \
  || version_fail "after the agent process exited the pane reads '$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")' rather than 'shell' through pane process-info. Raw process-info: $(lab pane process-info --pane "$PANE_ID" 2>&1 | tr -d '\n')"

# The divergence that makes this case non-vacuous: Herdr's own registry still
# reports the agent, and only the process-level view disagrees.
REGISTERED=$(lab agent get "$PANE_ID" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
[ -n "$REGISTERED" ] \
  || version_fail "Herdr released the registration when the agent process exited, so this run cannot prove the stale-registration path; the classifier still reads dead through agent_not_found"

PANE_STATE=$(fm_backend_herdr_pane_agent_state "$SESSION" "$PANE_ID")
[ "$PANE_STATE" = stale-agent ] \
  || version_fail "a registration over a shell-only pane reads '$PANE_STATE' rather than 'stale-agent'"
STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = dead ] \
  || version_fail "a registration over a shell-only pane recovers as '$STATE' rather than 'dead'; every relaunch would be refused"
pass "real herdr $HERDR_VERSION: a registration Herdr keeps after its agent exits reads stale-agent and recovers as dead"

OUT=$(run_control hsmoke exit) || fail "exit against a stale-registration pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "a stale-registration pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a pane with a stale registration is idempotent success"

wait_relaunch_shell_settled \
  || version_fail "the shell exposed after the stale agent exited did not settle to one relaunch-safe process"

rm -f "$SCRATCH/codex-launched"
OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" hsmoke --relaunch --harness codex) \
  || fail "a stale-registration Herdr pane should be relaunched: $OUT"
for _ in $(seq 1 20); do
  [ ! -e "$SCRATCH/codex-launched" ] || break
  sleep 0.1
done
[ -e "$SCRATCH/codex-launched" ] || fail "the replacement harness was not launched after the stale registration"
[ "$(sed -n 's/^window=//p' "$HOME_DIR/state/hsmoke.meta" | tail -1)" = "$SESSION:$PANE_ID" ] \
  || fail "the relaunch replaced its endpoint instead of reusing it"
lab pane get "$PANE_ID" >/dev/null 2>&1 \
  || fail "the relaunch removed the endpoint it was required to reuse"
[ -d "$WT" ] || fail "the relaunch must never remove the task's local copy"
awk -F= '$1 == "harness" {$0="harness=claude"} {print}' "$HOME_DIR/state/hsmoke.meta" \
  > "$HOME_DIR/state/hsmoke.meta.tmp"
mv "$HOME_DIR/state/hsmoke.meta.tmp" "$HOME_DIR/state/hsmoke.meta"
pass "real herdr: a stale registration no longer blocks relaunch, and the endpoint and local copy survive"

# Last: the foreground process is a plain `sleep`, so the pane never draws any
# recognized composer chrome. exit's composer-empty guard (bin/fm-control.sh)
# therefore refuses before ever typing the exit command, rather than typing it
# into a live agent that ignores it and reporting a stop that did not happen.
start_agent_process
lab pane report-agent "$PANE_ID" --source fm-control-smoke --agent fm-control-smoke-agent \
  --state idle >/dev/null 2>&1 \
  || fail "could not re-register the live agent on the task pane"
if OUT=$(run_control hsmoke exit 2>&1); then
  fail "exit should fail closed when the agent's composer is not proven empty: $OUT"
fi
case "$OUT" in
  *"not proven empty"*|*"visibly holds pending text"*) : ;;
  *) fail "the exit failure should identify pending or unproven composer input, got: $OUT" ;;
esac
pass "real herdr: an agent behind pending or unproven composer input fails closed instead of typing an exit command into it"

# --- nested-shell task cleanup: landing proof still owns destruction --------
#
# Relaunch and cleanup use deliberately different shell predicates. A nested
# Treehouse shell is eligible for relaunch, while cleanup first proves landing
# and then closes the exact pane even when its focus-safe pane-death shortcut
# cannot use the top-level childless-shell proof.
cat > "$FAKEBIN/treehouse" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TREEHOUSE_LOG:?}"
exit 0
EOF
chmod +x "$FAKEBIN/treehouse"

write_cleanup_meta() {  # <id> <wt> <tab> <pane>
  local id=$1 wt=$2 tab=$3 pane=$4
  {
    echo "window=$SESSION:$pane"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$PROJ"
    echo "harness=pi"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "backend=herdr"
    echo "herdr_session=$SESSION"
    echo "herdr_workspace_id=$WORKSPACE_ID"
    echo "herdr_tab_id=$tab"
    echo "herdr_pane_id=$pane"
  } > "$HOME_DIR/state/$id.meta"
}

wait_nested_shell() {  # <pane>
  local pane=$1 info outer foreground i=0
  while [ "$i" -lt 50 ]; do
    info=$(lab pane process-info --pane "$pane" 2>/dev/null || true)
    outer=$(printf '%s' "$info" | jq -r '.result.process_info.shell_pid // empty' 2>/dev/null)
    foreground=$(printf '%s' "$info" | jq -r '.result.process_info.foreground_processes[0].pid // empty' 2>/dev/null)
    if [ -n "$outer" ] && [ -n "$foreground" ] && [ "$outer" != "$foreground" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

CLEAN_ID=hclean-nested
CLEAN_WT="$SCRATCH/clean-wt"
git -C "$PROJ" worktree add --quiet -b "$CLEAN_ID" "$CLEAN_WT"
CLEAN_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-$CLEAN_ID" "$CLEAN_WT" "") \
  || fail "could not create landed nested cleanup pane"
read -r CLEAN_TAB_ID CLEAN_PANE_ID <<EOF
$CLEAN_IDS
EOF
write_cleanup_meta "$CLEAN_ID" "$CLEAN_WT" "$CLEAN_TAB_ID" "$CLEAN_PANE_ID"
lab pane run "$CLEAN_PANE_ID" zsh >/dev/null 2>&1 || fail "could not enter the landed nested cleanup shell"
wait_nested_shell "$CLEAN_PANE_ID" || version_fail "the landed cleanup pane did not reach a nested-shell shape"
TREEHOUSE_LOG="$SCRATCH/clean-treehouse.log"
: > "$TREEHOUSE_LOG"
OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_TREEHOUSE_LOG="$TREEHOUSE_LOG" \
  PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-teardown.sh" "$CLEAN_ID" 2>&1) \
  || fail "landed nested-shell cleanup should complete: $OUT"
[ ! -e "$HOME_DIR/state/$CLEAN_ID.meta" ] || fail "landed nested-shell cleanup retained task metadata"
if lab pane get "$CLEAN_PANE_ID" >/dev/null 2>&1; then
  fail "landed nested-shell cleanup left the exact pane alive"
fi
grep -Fq "return --force $CLEAN_WT" "$TREEHOUSE_LOG" \
  || fail "landed nested-shell cleanup did not return the exact isolated worktree"
pass "real herdr: landed work in a nested-shell endpoint closes the exact pane and returns its isolated worktree"

DIRTY_ID=hdirty-nested
DIRTY_WT="$SCRATCH/dirty-wt"
git -C "$PROJ" worktree add --quiet -b "$DIRTY_ID" "$DIRTY_WT"
DIRTY_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-$DIRTY_ID" "$DIRTY_WT" "") \
  || fail "could not create unlanded nested cleanup pane"
read -r DIRTY_TAB_ID DIRTY_PANE_ID <<EOF
$DIRTY_IDS
EOF
write_cleanup_meta "$DIRTY_ID" "$DIRTY_WT" "$DIRTY_TAB_ID" "$DIRTY_PANE_ID"
lab pane run "$DIRTY_PANE_ID" zsh >/dev/null 2>&1 || fail "could not enter the unlanded nested cleanup shell"
wait_nested_shell "$DIRTY_PANE_ID" || version_fail "the unlanded cleanup pane did not reach a nested-shell shape"
printf 'unlanded work\n' > "$DIRTY_WT/unlanded.txt"
TREEHOUSE_LOG="$SCRATCH/dirty-treehouse.log"
: > "$TREEHOUSE_LOG"
if OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_TREEHOUSE_LOG="$TREEHOUSE_LOG" \
  PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-teardown.sh" "$DIRTY_ID" 2>&1); then
  fail "unlanded nested-shell cleanup unexpectedly succeeded: $OUT"
fi
case "$OUT" in
  *"uncommitted changes"*) : ;;
  *) fail "unlanded nested-shell cleanup did not name its preservation reason: $OUT" ;;
esac
[ -e "$HOME_DIR/state/$DIRTY_ID.meta" ] || fail "unlanded cleanup removed task metadata"
[ -e "$DIRTY_WT/unlanded.txt" ] || fail "unlanded cleanup discarded the dirty file"
[ ! -s "$TREEHOUSE_LOG" ] || fail "unlanded cleanup attempted to return the isolated worktree"
lab pane get "$DIRTY_PANE_ID" >/dev/null 2>&1 \
  || fail "unlanded cleanup closed the nested-shell endpoint"
lab pane close "$DIRTY_PANE_ID" >/dev/null 2>&1 || true
pass "real herdr: unlanded work refuses cleanup before the nested endpoint or isolated worktree is touched"

fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true
