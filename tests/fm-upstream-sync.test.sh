#!/usr/bin/env bash
# Public-interface coverage for the guarded Firstmate fork/upstream drift check
# and manual ancestry-preserving reconciliation command.
#
# Every fixture configures the real canonical remote URLs, while a PATH-scoped
# Git transport routes only the commands' live reads and fetches to isolated bare
# repositories. Tests therefore exercise the operator commands, live remote HEAD
# discovery, fetches, result binding, branch guards, merge behavior, and conflict
# recovery without parsing implementation source or reaching public remotes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRIFT="$ROOT/bin/fm-upstream-drift.sh"
SYNC="$ROOT/bin/fm-upstream-sync.sh"
ORIGIN_URL=https://github.com/bcriswell/firstmate.git
UPSTREAM_URL=https://github.com/kunchenguid/firstmate.git

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-upstream-sync-tests)
WORLD_N=0
REAL_GIT=$(command -v git)
FAKE_GIT_DIR="$TMP_ROOT/fake-git"
mkdir -p "$FAKE_GIT_DIR"
cat > "$FAKE_GIT_DIR/git" <<'EOF'
#!/usr/bin/env bash
set -eu

if [ "$#" -ge 5 ] && [ "$1" = -C ] && [ "$2" = "$FM_TEST_REPO" ]; then
  repo=$2
  case "$3:$4" in
    ls-remote:--symref)
      case "$5" in
        origin) transport=$FM_TEST_ORIGIN ;;
        upstream) transport=$FM_TEST_UPSTREAM ;;
        *) exec "$FM_TEST_REAL_GIT" "$@" ;;
      esac
      printf 'ls-remote %s\n' "$5" >> "$FM_TEST_TRANSPORT_LOG"
      shift 5
      exec "$FM_TEST_REAL_GIT" -C "$repo" ls-remote --symref "$transport" "$@"
      ;;
    fetch:--no-tags)
      case "$5" in
        origin) transport=$FM_TEST_ORIGIN ;;
        upstream) transport=$FM_TEST_UPSTREAM ;;
        *) exec "$FM_TEST_REAL_GIT" "$@" ;;
      esac
      printf 'fetch %s\n' "$5" >> "$FM_TEST_TRANSPORT_LOG"
      shift 5
      exec "$FM_TEST_REAL_GIT" -C "$repo" fetch --no-tags "$transport" "$@"
      ;;
  esac
fi
exec "$FM_TEST_REAL_GIT" "$@"
EOF
chmod +x "$FAKE_GIT_DIR/git"

commit_file() {  # <repo> <file> <content> <message>
  local repo=$1 file=$2 content=$3 message=$4
  mkdir -p "$(dirname "$repo/$file")"
  printf '%s\n' "$content" > "$repo/$file"
  git -C "$repo" add -- "$file"
  git -C "$repo" commit -qm "$message"
}

new_world() {
  local name=$1 w seed
  WORLD_N=$((WORLD_N + 1))
  w="$TMP_ROOT/$WORLD_N-$name"
  seed="$w/seed"
  mkdir -p "$w"
  git init -q -b main "$seed"
  printf 'base\n' > "$seed/shared.txt"
  printf 'base\n' > "$seed/base.txt"
  git -C "$seed" add shared.txt base.txt
  git -C "$seed" commit -qm base
  git clone -q --bare "$seed" "$w/fork.git"
  git clone -q --bare "$seed" "$w/upstream.git"
  git -C "$w/fork.git" symbolic-ref HEAD refs/heads/main
  git -C "$w/upstream.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/fork.git" "$w/repo"
  git clone -q "$w/fork.git" "$w/fork-work"
  git clone -q "$w/upstream.git" "$w/upstream-work"

  git -C "$w/repo" remote set-url origin "$ORIGIN_URL"
  git -C "$w/repo" remote add upstream "$UPSTREAM_URL"
  printf '%s\n' "$w"
}

advance_fork() {  # <world> <file> <content> <message>
  local w=$1
  shift
  commit_file "$w/fork-work" "$@"
  git -C "$w/fork-work" push -q origin main
}

advance_upstream() {  # <world> <file> <content> <message>
  local w=$1
  shift
  commit_file "$w/upstream-work" "$@"
  git -C "$w/upstream-work" push -q origin main
}

run_drift() {  # <world>
  local w=$1
  run_drift_for_repo "$w" "$w/repo" "$w/drift.result"
}

run_drift_for_repo() {  # <world> <repo> <result>
  local w=$1 repo=$2 result=$3
  PATH="$FAKE_GIT_DIR:$PATH" \
    FM_TEST_REAL_GIT="$REAL_GIT" \
    FM_TEST_REPO="$repo" \
    FM_TEST_ORIGIN="$w/fork.git" \
    FM_TEST_UPSTREAM="$w/upstream.git" \
    FM_TEST_TRANSPORT_LOG="$w/transport.log" \
    "$DRIFT" --repo "$repo" --result "$result" 2>&1
}

make_sync_branch() {  # <world> <branch>
  git -C "$1/repo" checkout -q -b "$2" origin/main
}

run_sync() {  # <world> <branch>
  local w=$1 branch=$2
  PATH="$FAKE_GIT_DIR:$PATH" \
    FM_TEST_REAL_GIT="$REAL_GIT" \
    FM_TEST_REPO="$w/repo" \
    FM_TEST_ORIGIN="$w/fork.git" \
    FM_TEST_UPSTREAM="$w/upstream.git" \
    FM_TEST_TRANSPORT_LOG="$w/transport.log" \
    "$SYNC" --repo "$w/repo" --result "$w/drift.result" --branch "$branch" 2>&1
}

assert_relationship() {  # <world> <relationship>
  assert_grep "relationship=$2" "$1/drift.result" "drift result did not record relationship $2"
}

assert_exact_merge() {  # <repo> <fork-tip> <upstream-tip>
  local repo=$1 fork_tip=$2 upstream_tip=$3
  assert_equals "$fork_tip" "$(git -C "$repo" rev-parse HEAD^1)" "merge first parent is not the fork tip"
  assert_equals "$upstream_tip" "$(git -C "$repo" rev-parse HEAD^2)" "merge second parent is not the upstream tip"
  ! git -C "$repo" rev-parse --verify HEAD^3 >/dev/null 2>&1 || fail "reconciliation commit has more than two parents"
  git -C "$repo" merge-base --is-ancestor "$fork_tip" HEAD || fail "fork tip is not retained as an ancestor"
  git -C "$repo" merge-base --is-ancestor "$upstream_tip" HEAD || fail "upstream tip is not retained as an ancestor"
}

# --- complete relationship classification and no-op paths ------------------

test_clean_no_drift_noops() {
  local w out before
  w=$(new_world no-drift)
  out=$(run_drift "$w") || fail "clean no-drift check failed:$out"
  assert_contains "$out" "relationship no-drift" "no-drift output is unclear"
  assert_relationship "$w" no-drift
  make_sync_branch "$w" sync/no-drift
  before=$(git -C "$w/repo" rev-parse HEAD)
  out=$(run_sync "$w" sync/no-drift) || fail "no-drift sync failed:$out"
  assert_contains "$out" "no-op; fork and upstream are already synchronized" "no-drift sync was not an explicit no-op"
  assert_equals "$before" "$(git -C "$w/repo" rev-parse HEAD)" "no-drift sync changed HEAD"
  pass "upstream drift/sync: clean no-drift is a stable no-op"
}

test_fork_ahead_noops() {
  local w out fork_tip
  w=$(new_world fork-ahead)
  advance_fork "$w" fork-only.txt fork-only fork-only
  out=$(run_drift "$w") || fail "fork-ahead check failed:$out"
  assert_relationship "$w" upstream-behind-fork
  make_sync_branch "$w" sync/fork-ahead
  fork_tip=$(git -C "$w/repo" rev-parse origin/main)
  out=$(run_sync "$w" sync/fork-ahead) || fail "fork-ahead sync failed:$out"
  assert_contains "$out" "no-op; fork $fork_tip already contains upstream" "fork-ahead sync was not an explicit no-op"
  assert_equals "$fork_tip" "$(git -C "$w/repo" rev-parse HEAD)" "fork-ahead sync changed HEAD"
  pass "upstream drift/sync: an upstream-behind fork is preserved unchanged"
}

# --- real merges preserve exact ancestry and fork-only changes -------------

test_fork_behind_creates_real_merge() {
  local w out fork_tip upstream_tip merged
  w=$(new_world fork-behind)
  advance_upstream "$w" upstream.txt upstream-change upstream-change
  out=$(run_drift "$w") || fail "fork-behind check failed:$out"
  assert_relationship "$w" fork-behind-upstream
  make_sync_branch "$w" sync/fork-behind
  fork_tip=$(git -C "$w/repo" rev-parse origin/main)
  upstream_tip=$(git -C "$w/repo" rev-parse upstream/main)
  out=$(run_sync "$w" sync/fork-behind) || fail "fork-behind sync failed:$out"
  assert_contains "$out" "created merge" "fork-behind sync did not report its merge"
  assert_exact_merge "$w/repo" "$fork_tip" "$upstream_tip"
  assert_grep upstream-change "$w/repo/upstream.txt" "upstream content was not retained"
  merged=$(git -C "$w/repo" rev-parse HEAD)
  out=$(run_sync "$w" sync/fork-behind) || fail "idempotent rerun failed:$out"
  assert_contains "$out" "current branch already has exact fork parent" "repeat run was not an exact-merge no-op"
  assert_equals "$merged" "$(git -C "$w/repo" rev-parse HEAD)" "repeat run created another commit"
  pass "upstream sync: fork-behind reconciliation creates one repeatable real merge"
}

test_divergence_preserves_both_histories() {
  local w out fork_tip upstream_tip local_main
  w=$(new_world divergence)
  advance_fork "$w" fork-only.txt fork-change fork-change
  advance_upstream "$w" upstream-only.txt upstream-change upstream-change
  out=$(run_drift "$w") || fail "divergence check failed:$out"
  assert_relationship "$w" divergence
  make_sync_branch "$w" sync/divergence
  fork_tip=$(git -C "$w/repo" rev-parse origin/main)
  upstream_tip=$(git -C "$w/repo" rev-parse upstream/main)
  local_main=$(git -C "$w/repo" rev-parse main)
  out=$(run_sync "$w" sync/divergence) || fail "divergence sync failed:$out"
  assert_exact_merge "$w/repo" "$fork_tip" "$upstream_tip"
  assert_grep fork-change "$w/repo/fork-only.txt" "fork-only content was lost"
  assert_grep upstream-change "$w/repo/upstream-only.txt" "upstream-only content was lost"
  assert_equals "$local_main" "$(git -C "$w/repo" rev-parse main)" "local default branch was written"
  pass "upstream sync: divergence keeps upstream ancestry and every fork-only commit"
}

# --- stale results and local-state guards refuse before mutation ------------

test_stale_result_race_refuses() {
  local w out rc before
  w=$(new_world stale)
  advance_upstream "$w" upstream-1.txt one upstream-one
  out=$(run_drift "$w") || fail "initial race check failed:$out"
  make_sync_branch "$w" sync/stale
  before=$(git -C "$w/repo" rev-parse HEAD)
  advance_upstream "$w" upstream-2.txt two upstream-two
  out=$(run_sync "$w" sync/stale); rc=$?
  expect_code 1 "$rc" "stale-result race"
  assert_contains "$out" "supplied drift result is stale" "stale-result refusal was not concrete"
  assert_equals "$before" "$(git -C "$w/repo" rev-parse HEAD)" "stale-result refusal changed HEAD"
  ! git -C "$w/repo" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 || fail "stale-result refusal started a merge"
  pass "upstream sync: a remote race invalidates the exact prior result"
}

test_wrong_branch_and_dirty_tree_refuse() {
  local w out rc before
  w=$(new_world local-guards)
  out=$(run_drift "$w") || fail "local-guard drift check failed:$out"
  before=$(git -C "$w/repo" rev-parse HEAD)
  out=$(run_sync "$w" sync/expected); rc=$?
  expect_code 1 "$rc" "wrong-branch refusal"
  assert_contains "$out" "current branch is 'main'" "wrong-branch refusal did not name the current branch"
  assert_equals "$before" "$(git -C "$w/repo" rev-parse HEAD)" "wrong-branch refusal changed HEAD"

  make_sync_branch "$w" sync/expected
  printf 'uncommitted\n' > "$w/repo/dirty.txt"
  out=$(run_sync "$w" sync/expected); rc=$?
  expect_code 1 "$rc" "dirty-tree refusal"
  assert_contains "$out" "is dirty" "dirty-tree refusal was not concrete"
  assert_grep uncommitted "$w/repo/dirty.txt" "dirty work was not preserved"
  pass "upstream sync: wrong-branch and dirty-tree states are preserved and refused"
}

# --- conflicts remain recoverable and never report success -----------------

test_conflict_leaves_recoverable_evidence() {
  local w out rc before
  w=$(new_world conflict)
  commit_file "$w/fork-work" shared.txt fork-version fork-conflict
  git -C "$w/fork-work" push -q origin main
  commit_file "$w/upstream-work" shared.txt upstream-version upstream-conflict
  git -C "$w/upstream-work" push -q origin main
  out=$(run_drift "$w") || fail "conflict drift check failed:$out"
  assert_relationship "$w" divergence
  make_sync_branch "$w" sync/conflict
  before=$(git -C "$w/repo" rev-parse HEAD)
  out=$(run_sync "$w" sync/conflict); rc=$?
  expect_code 1 "$rc" "conflicting reconciliation"
  assert_contains "$out" "merge has conflicts" "conflict refusal did not name recoverable state"
  assert_contains "$out" "git merge --abort" "conflict refusal omitted its recovery path"
  git -C "$w/repo" rev-parse -q --verify MERGE_HEAD >/dev/null || fail "conflict did not retain MERGE_HEAD evidence"
  git -C "$w/repo" ls-files -u | grep -q . || fail "conflict did not retain unmerged index evidence"
  assert_equals "$before" "$(git -C "$w/repo" rev-parse HEAD)" "conflict advanced HEAD"
  git -C "$w/repo" merge --abort
  pass "upstream sync: conflicts stop with intact recoverable Git evidence"
}

# --- remote identity, default, availability, and completeness guards --------

test_unexpected_remote_identity_refuses() {
  local w out rc
  w=$(new_world bad-url)
  git -C "$w/repo" remote set-url upstream https://example.invalid/not-firstmate.git
  out=$(run_drift "$w"); rc=$?
  expect_code 1 "$rc" "unexpected-remote refusal"
  assert_contains "$out" "remote 'upstream' must have exactly URL '$UPSTREAM_URL'" "unexpected remote identity was not named"
  [ ! -e "$w/drift.result" ] || fail "unexpected remote identity published a result"
  pass "upstream drift: unexpected remote identity refuses before fetch"
}

test_effective_remote_rewrite_refuses() {
  local w out rc
  w=$(new_world rewritten-url)
  git -C "$w/repo" config "url.file://$w/upstream.git.insteadOf" "$UPSTREAM_URL"
  out=$(run_drift "$w"); rc=$?
  expect_code 1 "$rc" "effective-remote-rewrite refusal"
  assert_contains "$out" "remote 'upstream' effective fetch URL must be '$UPSTREAM_URL'" "effective remote rewrite was not named"
  [ ! -e "$w/drift.result" ] || fail "effective remote rewrite published a result"
  [ ! -e "$w/transport.log" ] || fail "effective remote rewrite reached a live remote operation"
  pass "upstream drift: URL rewriting cannot bypass canonical remote identity"
}

test_custom_remote_vcs_refuses() {
  local w out rc
  w=$(new_world custom-vcs)
  git -C "$w/repo" config remote.upstream.vcs fm-test-helper
  out=$(run_drift "$w"); rc=$?
  expect_code 1 "$rc" "custom-remote-vcs refusal"
  assert_contains "$out" "remote 'upstream' has an unexpected VCS helper" "custom remote VCS helper was not named"
  [ ! -e "$w/drift.result" ] || fail "custom remote VCS helper published a result"
  [ ! -e "$w/transport.log" ] || fail "custom remote VCS helper reached a live remote operation"
  pass "upstream drift: custom VCS helpers cannot bypass remote identity"
}

test_unexpected_default_and_unavailable_remote_refuse() {
  local w out rc
  w=$(new_world bad-default)
  git -C "$w/upstream-work" push -q origin main:trunk
  git -C "$w/upstream.git" symbolic-ref HEAD refs/heads/trunk
  out=$(run_drift "$w"); rc=$?
  expect_code 1 "$rc" "unexpected-default refusal"
  assert_contains "$out" "default branch is 'trunk', expected 'main'" "unexpected default branch was not named"

  w=$(new_world unavailable)
  mv "$w/upstream.git" "$w/upstream-gone.git"
  out=$(run_drift "$w"); rc=$?
  expect_code 1 "$rc" "unavailable-remote refusal"
  assert_contains "$out" "could not read live 'upstream' refs" "unavailable remote did not produce a network diagnostic"
  pass "upstream drift: unexpected defaults and unavailable remotes stop concretely"
}

test_shallow_history_refuses() {
  local w shallow out rc
  w=$(new_world shallow)
  shallow="$w/shallow"
  git clone -q --depth 1 "file://$w/fork.git" "$shallow"
  git -C "$shallow" remote set-url origin "$ORIGIN_URL"
  git -C "$shallow" remote add upstream "$UPSTREAM_URL"
  out=$(run_drift_for_repo "$w" "$shallow" "$w/shallow.result"); rc=$?
  expect_code 1 "$rc" "shallow-history refusal"
  assert_contains "$out" "history is shallow" "shallow-history refusal was not concrete"
  [ ! -e "$w/shallow.result" ] || fail "shallow history published a result"
  pass "upstream drift: incomplete history refuses rather than guessing ancestry"
}

test_clean_no_drift_noops
test_fork_ahead_noops
test_fork_behind_creates_real_merge
test_divergence_preserves_both_histories
test_stale_result_race_refuses
test_wrong_branch_and_dirty_tree_refuse
test_conflict_leaves_recoverable_evidence
test_unexpected_remote_identity_refuses
test_effective_remote_rewrite_refuses
test_custom_remote_vcs_refuses
test_unexpected_default_and_unavailable_remote_refuse
test_shallow_history_refuses
