#!/usr/bin/env bash
# Default-on live guard for the Herdr stale-registration classifier (issue
# #4115) against the REAL Pi harness under the REAL Herdr binary.
#
# The defect: Herdr keeps a Pi registration (`agent get` -> agent=pi,
# agent_status=idle) after the Pi process has exited to a plain shell whenever
# a nested interactive shell sits under the pane's top shell - the crew shape,
# where `treehouse get` leaves a worktree shell under the pane's login shell.
# The adapter now proves an agent at process level before trusting a
# registration and tracks Treehouse's nested foreground shell during relaunch.
# This guard measures the three vendor facts that no fixture can prove:
#
#   1. how Pi presents in `pane process-info` (on Herdr 0.9.0 the kernel name
#      is `node` and only argv0 says `pi`), so the shared process classifier
#      must still attribute the running harness as `agent`;
#   2. whether this Herdr release still leaves the registration behind after
#      Pi quits under a nested shell, so the stale-registration branch is
#      exercised against the real record rather than a canned one;
#   3. whether the completed Pi leaves a distinct foreground nested shell that
#      the real spawn path can relaunch in the same endpoint and worktree.
#
# It fails naming the Herdr and Pi versions when any fact drifts. Pi is
# launched with no prompt and quit immediately, so no model token is spent and
# the shared live gate runs it by default wherever both tools are installed.
# Run it after every Herdr or Pi upgrade and before trusting a refreshed
# docs/verification/runtime-backends.md "Stale agent registration" entry.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; bin/fm-herdr-lab.sh owns the isolation).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

fm_live_gate default-on FM_HERDR_PI_STALE_REGISTRATION_LIVE_E2E herdr pi jq

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$HERDR_LAB_HELPER" ] || fail "Herdr lab helper is not executable: $HERDR_LAB_HELPER"
SESSION=$("$HERDR_LAB_HELPER" name fm-pi-stale) || fail "could not generate isolated Herdr lab session name"
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

HERDR_VERSION=$("$HERDR_LAB_HELPER" run "$SESSION" status --json 2>/dev/null \
  | jq -r '.client.version // "unknown"')
PI_VERSION=$(pi --version 2>/dev/null | head -1 | tr -d '\r')
[ -n "$PI_VERSION" ] || PI_VERSION=unknown
version_fail() {  # <message>
  fail "$1 [herdr $HERDR_VERSION, pi $PI_VERSION]"
}

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-stale.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
ID=pi-nested-relaunch
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/$ID" "$PROJ"
git -C "$PROJ" init -q
printf '# nested Pi relaunch fixture\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b "$ID" "$WT"
cat > "$HOME_DIR/data/$ID/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise a real Pi relaunch from Treehouse's nested-shell shape.

## Firstmate spec
Reuse the exact endpoint and isolated worktree.
EOF

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

lab() { "$HERDR_LAB_HELPER" run "$SESSION" "$@"; }

WS=$(lab workspace create --label fm-pi-stale --cwd "$WT" 2>&1) \
  || fail "could not create the lab workspace: $WS"
WORKSPACE_ID=$(printf '%s' "$WS" | jq -r '.result.workspace.workspace_id // empty')
TAB_ID=$(printf '%s' "$WS" | jq -r '.result.tab.tab_id // empty')
PANE_ID=$(printf '%s' "$WS" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$WORKSPACE_ID" ] && [ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] \
  || fail "workspace create did not return complete workspace, tab, and pane ids"
TARGET="$SESSION:$PANE_ID"
{
  echo "window=$TARGET"
  echo "endpoint_task_id=$ID"
  echo "worktree=$WT"
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
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/$ID.meta"

wait_process_state() {  # <expected> <tries>
  local expected=$1 tries=$2 got i=0
  while [ "$i" -lt "$tries" ]; do
    got=$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")
    [ "$got" = "$expected" ] && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

registered_status() {
  lab agent get "$PANE_ID" 2>/dev/null | jq -r '.result.agent.agent_status // empty'
}

# The crew shape: a nested interactive shell under the pane's top shell, then
# the real Pi TUI with no prompt.
lab pane run "$PANE_ID" zsh >/dev/null 2>&1 || fail "could not start the nested shell in the pane"
sleep 1
lab pane run "$PANE_ID" pi >/dev/null 2>&1 || fail "could not start pi in the pane"

# Herdr creates the record with its own placeholder status (`unknown`, verified
# 0.9.0) the moment it notices Pi, before Pi's extension reports a lifecycle
# state; only a lifecycle state is the registration this guard is about.
STATUS=
for _ in $(seq 1 300); do
  STATUS=$(registered_status)
  case "$STATUS" in working|idle|done|blocked) break ;; esac
  sleep 0.2
done
case "$STATUS" in
  working|idle|done|blocked) ;;
  *) version_fail \
    "pi never reported a lifecycle state to Herdr in this pane (agent get read '${STATUS:-agent_not_found}' for 60s); the herdr pi integration (~/.pi/agent/extensions/herdr-agent-state.ts) is what reports it" ;;
esac

wait_process_state agent 100 || version_fail \
  "pi is running and registered ($STATUS) but pane process-info reads '$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")', not 'agent'. Observed foreground: $(lab pane process-info --pane "$PANE_ID" 2>/dev/null | jq -c '.result.process_info.foreground_processes'). Teach bin/fm-agent-process-lib.sh's fm_agent_process_classify the identity this release actually reports"
FOREGROUND=$(lab pane process-info --pane "$PANE_ID" 2>/dev/null \
  | jq -c '[.result.process_info.foreground_processes[] | {name, argv0}]')
STATE=$(fm_backend_agent_state herdr "$TARGET")
[ "$STATE" = alive ] || version_fail "a running, registered pi reads '$STATE' rather than 'alive' (registration '$(registered_status)', pane state '$(fm_backend_herdr_pane_agent_state "$SESSION" "$PANE_ID")', process state '$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")', agent get: $(lab agent get "$PANE_ID" 2>&1 | tr -d '\n'))"
note "pi $PI_VERSION under herdr $HERDR_VERSION: registered $STATUS, foreground $FOREGROUND"
pass "real herdr $HERDR_VERSION + pi $PI_VERSION: a running registered pi classifies alive at process level"

# Quit Pi to the nested shell. A slash command can open a completion popup that
# swallows the first Enter, so one extra Enter is allowed before judging.
lab pane send-text "$PANE_ID" '/quit' >/dev/null 2>&1 || fail "could not type /quit"
sleep 0.5
lab pane send-keys "$PANE_ID" Enter >/dev/null 2>&1 || fail "could not submit /quit"
if ! wait_process_state shell 50; then
  lab pane send-keys "$PANE_ID" Enter >/dev/null 2>&1 || true
  wait_process_state shell 150 || version_fail \
    "pi did not exit to a shell within 40s of /quit; pane process-info reads '$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")'"
fi

# Let Herdr settle whatever release it is going to do, then read the record.
sleep 2
STATUS=$(registered_status)
PANE_STATE=$(fm_backend_herdr_pane_agent_state "$SESSION" "$PANE_ID")
STATE=$(fm_backend_agent_state herdr "$TARGET")
BUSY=$(fm_backend_herdr_busy_state "$TARGET")
[ "$STATE" = dead ] || version_fail \
  "after pi quit to a shell the endpoint recovers as '$STATE' (pane state '$PANE_STATE', registration '${STATUS:-none}') rather than 'dead'; every relaunch would be refused"
[ "$BUSY" != busy ] || version_fail "a shell-only pane after pi quit reads busy (registration '${STATUS:-none}')"
if [ -n "$STATUS" ]; then
  [ "$PANE_STATE" = stale-agent ] || version_fail \
    "Herdr kept the registration ($STATUS) over the shell-only pane but the classifier reads '$PANE_STATE' rather than 'stale-agent'"
  note "herdr $HERDR_VERSION kept the pi registration ($STATUS) after /quit under a nested shell: the stale-registration branch is exercised"
  pass "real herdr $HERDR_VERSION + pi $PI_VERSION: the registration left behind by a quit pi reads stale-agent and recovers as dead"
else
  [ "$PANE_STATE" = no-agent ] || version_fail \
    "Herdr released the registration but the pane reads '$PANE_STATE' rather than 'no-agent'"
  note "herdr $HERDR_VERSION released the pi registration after /quit under a nested shell; the stale-registration branch was not exercised by this release, the agent-free verdict still held through agent_not_found"
  pass "real herdr $HERDR_VERSION + pi $PI_VERSION: a quit pi under a nested shell recovers as dead"
fi

PROCESS_INFO=$(lab pane process-info --pane "$PANE_ID" 2>/dev/null) \
  || version_fail "could not read the completed Pi pane before relaunch"
OUTER_SHELL_PID=$(printf '%s' "$PROCESS_INFO" | jq -r '.result.process_info.shell_pid // empty')
FOREGROUND_SHELL_PID=$(printf '%s' "$PROCESS_INFO" | jq -r '.result.process_info.foreground_processes[0].pid // empty')
[ -n "$OUTER_SHELL_PID" ] && [ -n "$FOREGROUND_SHELL_PID" ] \
  || version_fail "the completed Pi pane did not expose both outer and foreground shell identities"
[ "$OUTER_SHELL_PID" != "$FOREGROUND_SHELL_PID" ] \
  || version_fail "the nested-shell regression became vacuous because the foreground shell equals Herdr's outer pane shell"

MARKER="$SCRATCH/relaunched-cwd"
OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" "$ID" --relaunch --harness "pwd > '$MARKER'" 2>&1) \
  || version_fail "a completed Pi in the nested shell could not be relaunched in place: $OUT"
for _ in $(seq 1 50); do
  [ ! -s "$MARKER" ] || break
  sleep 0.1
done
[ -s "$MARKER" ] || version_fail "the replacement command did not start after nested-shell relaunch"
EXPECTED=$(cd "$WT" && pwd -P)
LAUNCHED=$(cd "$(cat "$MARKER")" && pwd -P)
[ "$LAUNCHED" = "$EXPECTED" ] \
  || version_fail "the replacement launched in '$LAUNCHED', not the recorded worktree '$EXPECTED'"
[ "$(sed -n 's/^window=//p' "$HOME_DIR/state/$ID.meta" | tail -1)" = "$TARGET" ] \
  || version_fail "the nested-shell relaunch replaced the recorded endpoint"
lab pane get "$PANE_ID" >/dev/null 2>&1 \
  || version_fail "the nested-shell relaunch removed the endpoint it was required to reuse"
pass "real herdr $HERDR_VERSION + pi $PI_VERSION: a completed Pi relaunches from Treehouse's nested idle shell in the same endpoint and isolated worktree"
