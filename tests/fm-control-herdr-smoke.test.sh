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
# No real agent is launched. herdr's `pane report-agent` is the same registry
# the adapter reads, so registering and not registering an agent on a plain
# shell pane exercises exactly the classification the control plane gates on.
#
# Always runs through bin/fm-herdr-lab.sh on a private, named, throwaway
# session, never the default one. Skips cleanly when herdr or jq is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
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
  if [ "$LAB_OWNED" = 1 ]; then
    LAB_OWNED=0
    "$HERDR_LAB_HELPER" teardown "$SESSION"
  fi
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
}
trap cleanup_all EXIT
LAB_OWNED=1
"$HERDR_LAB_HELPER" provision "$SESSION" || fail "could not provision isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsmoke"
printf '# brief\n' > "$HOME_DIR/data/hsmoke/brief.md"

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsmoke "$WT"

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
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
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
printf '# brief\n\nDelivery contract: mode=no-mistakes\n' > "$HOME_DIR/data/$REROOT_ID/brief.md"
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

# --- a registered agent: classification flips, and the verbs follow ---------

"$HERDR_LAB_HELPER" run "$SESSION" pane report-agent "$PANE_ID" \
  --source fm-control-smoke --agent fm-control-smoke-agent --state idle >/dev/null 2>&1 \
  || fail "could not register a live agent on the task pane"

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = alive ] || fail "herdr should classify a registered agent as alive, got '$STATE'"

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

# Last, because it deliberately types a harness command into a pane that hosts
# a plain shell: the registered agent cannot actually be stopped that way, and
# the control plane must say so rather than report a stop it did not achieve.
if OUT=$(run_control hsmoke exit 2>&1); then
  fail "exit should fail closed when the agent does not stop: $OUT"
fi
case "$OUT" in
  *"did not stop"*) : ;;
  *) fail "the exit failure should say the agent did not stop, got: $OUT" ;;
esac
pass "real herdr: an agent that does not stop fails closed instead of being reported as stopped"

fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true
