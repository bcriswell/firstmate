#!/usr/bin/env bash
# Guarded manual reconciliation of kunchenguid/firstmate upstream into the
# bcriswell/firstmate fork. Scheduling is intentionally outside this command.
#
# A prior fm-upstream-drift.sh --result record is mandatory. Immediately before
# any merge, this command reruns that check, refreshes both live tips, and
# byte-compares a private snapshot of the supplied fm-upstream-drift-v1 record
# with the fresh result. Because the record binds the physical repository,
# exact remote URLs and defaults, object format, commits, merge base, and
# relationship, a stale result, moved remote, or substituted repository refuses.
#
# Mutation is allowed only when all of these remain true after the fresh check:
#   - --branch exactly names the current, explicit non-main branch;
#   - the worktree is clean and no other Git operation is active;
#   - HEAD is the freshly verified origin/main tip, or the exact two-parent
#     merge of that fork tip and the verified upstream tip from an earlier run.
# A repeated run on that exact merge and the no-drift and upstream-behind-fork
# relationships are successful no-ops. For
# fork-behind-upstream or divergence, the command runs a normal
# `git merge --no-ff --no-commit <verified-upstream-tip>`, verifies its tree
# against an isolated merge of the two tips, and atomically publishes one real
# merge commit whose first parent is the fork tip and second parent is the
# upstream tip. Fork-only commits therefore remain in ancestry.
#
# The command never checks out or writes main, pushes, opens or merges a pull
# request, force-updates, resets, stashes, discards work, changes remotes, or
# selects an automatic conflict resolution. A merge conflict returns nonzero
# with MERGE_HEAD and the index/worktree intact for inspection and explicit
# resolution or `git merge --abort`; it never reports success.
#
# Usage: fm-upstream-sync.sh --result <path> --branch <name>
#                            [--repo <path>] [--help]
# Example:
#   bin/fm-upstream-drift.sh --result state/upstream-drift.result
#   git switch -c sync/upstream-YYYYMMDD origin/main
#   bin/fm-upstream-sync.sh --result state/upstream-drift.result \
#     --branch sync/upstream-YYYYMMDD
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIFT="$SCRIPT_DIR/fm-upstream-drift.sh"
REPO=.
RESULT=
BRANCH=

usage() {
  cat <<'EOF'
usage: fm-upstream-sync.sh --result <path> --branch <name>
                           [--repo <path>] [--help]

Reconcile the verified live kunchenguid/firstmate main tip into the
bcriswell/firstmate fork with a real ancestry-preserving merge commit.

Required options:
  --result <path>  Result written by a prior fm-upstream-drift.sh check.
  --branch <name>  Exact current non-main reconciliation branch name.

Other options:
  --repo <path>    Repository to reconcile (default: current directory).
  -h, --help       Show this help.

Workflow:
  bin/fm-upstream-drift.sh --result state/upstream-drift.result
  git switch -c sync/upstream-YYYYMMDD origin/main
  bin/fm-upstream-sync.sh --result state/upstream-drift.result \
    --branch sync/upstream-YYYYMMDD

Exit status:
  0  The verified relationship required no merge, or a two-parent merge commit
     was created and its exact parents and ancestry were proved.
  1  A guard refused, the result became stale, fetching failed, committing
     failed, or a merge conflicted. A conflict remains intact and recoverable.

The command reruns the bounded drift check before mutation and requires its
byte-stable result to match the supplied record. It never writes main, pushes,
merges a pull request, forces, resets, stashes, discards, changes remotes, or
chooses a conflict resolution. On conflict, inspect `git status`, resolve and
commit explicitly if appropriate, or run `git merge --abort`.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || { echo "error: --repo requires a path" >&2; usage >&2; exit 1; }
      REPO=$2
      shift 2
      ;;
    --result)
      [ "$#" -ge 2 ] || { echo "error: --result requires a path" >&2; usage >&2; exit 1; }
      RESULT=$2
      shift 2
      ;;
    --branch)
      [ "$#" -ge 2 ] || { echo "error: --branch requires a name" >&2; usage >&2; exit 1; }
      BRANCH=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[ -n "$RESULT" ] || { echo "error: --result is required; run fm-upstream-drift.sh first" >&2; usage >&2; exit 1; }
[ -n "$BRANCH" ] || { echo "error: --branch is required" >&2; usage >&2; exit 1; }
[ -f "$RESULT" ] || { echo "error: drift result '$RESULT' is not a regular file" >&2; exit 1; }
[ -x "$DRIFT" ] || { echo "error: required drift command '$DRIFT' is not executable" >&2; exit 1; }
git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || {
  echo "error: reconciliation branch '$BRANCH' is not a valid branch name" >&2
  exit 1
}

REPO=$(cd -- "$REPO" 2>/dev/null && pwd -P) || {
  echo "error: repository path '$REPO' is not an accessible directory" >&2
  exit 1
}
top=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || {
  echo "error: '$REPO' is not inside a Git worktree" >&2
  exit 1
}
top=$(cd -- "$top" 2>/dev/null && pwd -P) || {
  echo "error: repository root '$top' is not accessible" >&2
  exit 1
}
[ "$top" = "$REPO" ] || {
  echo "error: --repo must name the physical Git worktree root (got '$REPO', root is '$top')" >&2
  exit 1
}

# Parse without sourcing: a result is data, never shell code. Unknown, duplicate,
# missing, or malformed fields are rejected before any network or Git mutation.
parse_result() {  # <path>
  local path=$1 line key value seen='|'
  R_FORMAT=''
  R_REPOSITORY=''
  R_OBJECT_FORMAT=''
  R_ORIGIN_URL=''
  R_ORIGIN_DEFAULT=''
  R_ORIGIN_TIP=''
  R_UPSTREAM_URL=''
  R_UPSTREAM_DEFAULT=''
  R_UPSTREAM_TIP=''
  R_MERGE_BASE=''
  R_RELATIONSHIP=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *$'\r'*|*$'\n'*)
        echo "error: drift result '$path' contains an unrepresentable line" >&2
        return 1
        ;;
      *=*) key=${line%%=*}; value=${line#*=} ;;
      *)
        echo "error: drift result '$path' contains a malformed line" >&2
        return 1
        ;;
    esac
    case "$seen" in
      *"|$key|"*)
        echo "error: drift result '$path' repeats field '$key'" >&2
        return 1
        ;;
    esac
    seen="$seen$key|"
    case "$key" in
      format) R_FORMAT=$value ;;
      repository) R_REPOSITORY=$value ;;
      object_format) R_OBJECT_FORMAT=$value ;;
      origin_url) R_ORIGIN_URL=$value ;;
      origin_default) R_ORIGIN_DEFAULT=$value ;;
      origin_tip) R_ORIGIN_TIP=$value ;;
      upstream_url) R_UPSTREAM_URL=$value ;;
      upstream_default) R_UPSTREAM_DEFAULT=$value ;;
      upstream_tip) R_UPSTREAM_TIP=$value ;;
      merge_base) R_MERGE_BASE=$value ;;
      relationship) R_RELATIONSHIP=$value ;;
      *)
        echo "error: drift result '$path' has unknown field '$key'" >&2
        return 1
        ;;
    esac
  done < "$path"

  [ "$seen" = '|format|repository|object_format|origin_url|origin_default|origin_tip|upstream_url|upstream_default|upstream_tip|merge_base|relationship|' ] || {
    echo "error: drift result '$path' fields are missing or out of canonical order" >&2
    return 1
  }
  [ "$R_FORMAT" = fm-upstream-drift-v1 ] || {
    echo "error: drift result '$path' has unsupported format '$R_FORMAT'" >&2
    return 1
  }
  case "$R_OBJECT_FORMAT" in sha1|sha256) ;; *)
    echo "error: drift result '$path' has unsupported object format '$R_OBJECT_FORMAT'" >&2
    return 1
    ;;
  esac
  case "$R_RELATIONSHIP" in
    no-drift|upstream-behind-fork|fork-behind-upstream|divergence) ;;
    *)
      echo "error: drift result '$path' has unknown relationship '$R_RELATIONSHIP'" >&2
      return 1
      ;;
  esac
  [ -n "$R_REPOSITORY" ] && [ -n "$R_ORIGIN_URL" ] && [ -n "$R_ORIGIN_DEFAULT" ] \
    && [ -n "$R_ORIGIN_TIP" ] && [ -n "$R_UPSTREAM_URL" ] \
    && [ -n "$R_UPSTREAM_DEFAULT" ] && [ -n "$R_UPSTREAM_TIP" ] \
    && [ -n "$R_MERGE_BASE" ] || {
      echo "error: drift result '$path' contains an empty required field" >&2
      return 1
    }
}

result_dir=$(dirname -- "$RESULT")
[ -d "$result_dir" ] || { echo "error: drift result directory '$result_dir' is missing" >&2; exit 1; }
frozen=$(mktemp "$result_dir/.fm-upstream-sync-supplied.XXXXXX") || {
  echo "error: could not snapshot drift result in '$result_dir'" >&2
  exit 1
}
fresh=$(mktemp "$result_dir/.fm-upstream-sync-fresh.XXXXXX") || {
  rm -f "$frozen"
  echo "error: could not create fresh drift result in '$result_dir'" >&2
  exit 1
}
trap 'rm -f "$frozen" "$fresh"' EXIT
cp -- "$RESULT" "$frozen"
chmod 600 "$frozen" "$fresh"
parse_result "$frozen" || exit 1

[ "$R_REPOSITORY" = "$REPO" ] || {
  echo "error: drift result belongs to repository '$R_REPOSITORY', not '$REPO'" >&2
  exit 1
}
[ "$BRANCH" != "$R_ORIGIN_DEFAULT" ] && [ "$BRANCH" != "$R_UPSTREAM_DEFAULT" ] || {
  echo "error: reconciliation branch '$BRANCH' is a protected default branch" >&2
  exit 1
}

ensure_branch_and_clean() {  # <expected-origin-tip> <expected-upstream-tip>
  local expected_tip=$1 expected_upstream_tip=$2 current dirty op head first_parent second_parent
  BRANCH_HEAD_STATE=
  current=$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ "$current" = "$BRANCH" ] || {
    if [ -z "$current" ]; then
      echo "error: reconciliation requires branch '$BRANCH', but HEAD is detached" >&2
    else
      echo "error: reconciliation requires current branch '$BRANCH', but current branch is '$current'" >&2
    fi
    return 1
  }
  for op in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    if git -C "$REPO" rev-parse -q --verify "$op" >/dev/null 2>&1; then
      echo "error: Git operation '$op' is already active; finish or abort it before upstream sync" >&2
      return 1
    fi
  done
  dirty=$(git -C "$REPO" status --porcelain=v1 --untracked-files=normal)
  [ -z "$dirty" ] || {
    echo "error: reconciliation branch '$BRANCH' is dirty; commit or otherwise preserve the work before upstream sync" >&2
    printf '%s\n' "$dirty" >&2
    return 1
  }
  head=$(git -C "$REPO" rev-parse --verify HEAD 2>/dev/null) || {
    echo "error: could not resolve HEAD on reconciliation branch '$BRANCH'" >&2
    return 1
  }
  if [ "$head" = "$expected_tip" ]; then
    BRANCH_HEAD_STATE=base
    return 0
  fi
  first_parent=$(git -C "$REPO" rev-parse --verify HEAD^1 2>/dev/null || true)
  second_parent=$(git -C "$REPO" rev-parse --verify HEAD^2 2>/dev/null || true)
  if [ "$first_parent" = "$expected_tip" ] \
    && [ "$second_parent" = "$expected_upstream_tip" ] \
    && ! git -C "$REPO" rev-parse --verify HEAD^3 >/dev/null 2>&1; then
    BRANCH_HEAD_STATE=reconciled
    return 0
  fi
  echo "error: reconciliation branch '$BRANCH' must start at current fork tip $expected_tip or be its exact merge with verified upstream tip $expected_upstream_tip (HEAD is $head)" >&2
  return 1
}

canonical_merge_tree() {  # <fork-tip> <upstream-tip>
  local fork_tip=$1 upstream_tip=$2 output rc normalized
  if output=$(GIT_NO_REPLACE_OBJECTS=1 git -C "$REPO" merge-tree --write-tree --no-messages \
      "$fork_tip" "$upstream_tip" 2>&1); then
    :
  else
    rc=$?
    echo "error: could not derive the canonical merge tree from the verified tips (exit $rc)" >&2
    [ -z "$output" ] || printf '%s\n' "$output" >&2
    return "$rc"
  fi
  case "$output" in
    ''|*$'\n'*)
      echo "error: canonical merge computation did not produce one tree" >&2
      return 1
      ;;
  esac
  normalized=$(GIT_NO_REPLACE_OBJECTS=1 git -C "$REPO" rev-parse --verify "$output^{tree}" 2>/dev/null) || {
    echo "error: canonical merge computation produced invalid tree '$output'" >&2
    return 1
  }
  [ "$normalized" = "$output" ] || {
    echo "error: canonical merge computation produced non-canonical tree '$output'" >&2
    return 1
  }
  printf '%s\n' "$normalized"
}

# Refuse obvious local-state hazards before paying for a second network check,
# then prove the same facts again against the freshly fetched origin tip.
ensure_branch_and_clean "$R_ORIGIN_TIP" "$R_UPSTREAM_TIP" || exit 1

if fresh_output=$("$DRIFT" --repo "$REPO" --result "$fresh" 2>&1); then
  :
else
  rc=$?
  echo "error: fresh upstream drift check failed; no merge was attempted" >&2
  [ -z "$fresh_output" ] || printf '%s\n' "$fresh_output" >&2
  exit "$rc"
fi

if ! cmp -s "$frozen" "$fresh"; then
  echo "error: supplied drift result is stale or does not match the freshly verified repository/remotes; no merge was attempted" >&2
  echo "error: rerun fm-upstream-drift.sh, inspect the new relationship, and invoke sync with that exact result" >&2
  exit 1
fi

parse_result "$fresh" || exit 1
ensure_branch_and_clean "$R_ORIGIN_TIP" "$R_UPSTREAM_TIP" || exit 1

printf '%s\n' "$fresh_output"
if [ "$BRANCH_HEAD_STATE" = reconciled ]; then
  expected_tree=$(canonical_merge_tree "$R_ORIGIN_TIP" "$R_UPSTREAM_TIP") || exit 1
  current_tree=$(GIT_NO_REPLACE_OBJECTS=1 git -C "$REPO" rev-parse --verify HEAD^{tree}) || {
    echo "error: could not resolve the current reconciliation tree" >&2
    exit 1
  }
  [ "$current_tree" = "$expected_tree" ] || {
    echo "error: current exact-parent merge tree does not match the canonical merge of the verified tips" >&2
    exit 1
  }
  echo "upstream-sync: no-op; current branch already has exact fork parent $R_ORIGIN_TIP and upstream parent $R_UPSTREAM_TIP"
  exit 0
fi
case "$R_RELATIONSHIP" in
  no-drift)
    echo "upstream-sync: no-op; fork and upstream are already synchronized at $R_ORIGIN_TIP"
    exit 0
    ;;
  upstream-behind-fork)
    echo "upstream-sync: no-op; fork $R_ORIGIN_TIP already contains upstream $R_UPSTREAM_TIP"
    exit 0
    ;;
  fork-behind-upstream|divergence) ;;
esac

if git -C "$REPO" merge --no-ff --no-commit "$R_UPSTREAM_TIP"; then
  :
else
  rc=$?
  if git -C "$REPO" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 \
    || git -C "$REPO" ls-files -u | grep -q .; then
    echo "error: upstream merge has conflicts; no success was recorded and the recoverable merge state remains intact" >&2
    echo "error: inspect 'git status', resolve and commit explicitly if appropriate, or run 'git merge --abort'" >&2
  else
    echo "error: Git refused the upstream merge before leaving a recoverable merge state (exit $rc)" >&2
  fi
  exit "$rc"
fi

merge_head=$(git -C "$REPO" rev-parse --verify MERGE_HEAD 2>/dev/null || true)
[ "$merge_head" = "$R_UPSTREAM_TIP" ] || {
  echo "error: prepared merge is not bound to verified upstream tip $R_UPSTREAM_TIP; leaving it for inspection" >&2
  exit 1
}

expected_tree=$(canonical_merge_tree "$R_ORIGIN_TIP" "$R_UPSTREAM_TIP") || exit 1
prepared_tree=$(GIT_NO_REPLACE_OBJECTS=1 git -C "$REPO" write-tree 2>/dev/null) || {
  echo "error: prepared merge index could not be written; recoverable merge state remains for inspection" >&2
  exit 1
}
[ "$prepared_tree" = "$expected_tree" ] || {
  echo "error: prepared merge tree does not match the canonical merge of the verified tips; no commit was published" >&2
  exit 1
}

new_head=$(GIT_NO_REPLACE_OBJECTS=1 git -C "$REPO" commit-tree "$expected_tree" \
  -p "$R_ORIGIN_TIP" -p "$R_UPSTREAM_TIP" \
  -m "Merge upstream main while preserving fork changes") || {
  echo "error: canonical merge commit could not be created; recoverable merge state remains for inspection" >&2
  exit 1
}
if ! git -C "$REPO" update-ref -m "merge upstream main while preserving fork changes" \
    "refs/heads/$BRANCH" "$new_head" "$R_ORIGIN_TIP"; then
  echo "error: reconciliation branch changed before the canonical merge could be published; no success was recorded" >&2
  exit 1
fi
if ! git -C "$REPO" merge --quit; then
  echo "error: canonical merge $new_head was published but Git could not clear the completed merge state" >&2
  exit 1
fi

published=$(git -C "$REPO" rev-parse --verify "refs/heads/$BRANCH")
commit_tree=$(GIT_NO_REPLACE_OBJECTS=1 git -C "$REPO" rev-parse --verify "$new_head^{tree}")
first_parent=$(git -C "$REPO" rev-parse --verify "$new_head^1")
second_parent=$(git -C "$REPO" rev-parse --verify "$new_head^2")
if [ "$published" != "$new_head" ] \
  || [ "$commit_tree" != "$expected_tree" ] \
  || git -C "$REPO" rev-parse --verify "$new_head^3" >/dev/null 2>&1 \
  || [ "$first_parent" != "$R_ORIGIN_TIP" ] \
  || [ "$second_parent" != "$R_UPSTREAM_TIP" ] \
  || ! GIT_NO_REPLACE_OBJECTS=1 git -C "$REPO" merge-base --is-ancestor "$R_ORIGIN_TIP" "$new_head" \
  || ! GIT_NO_REPLACE_OBJECTS=1 git -C "$REPO" merge-base --is-ancestor "$R_UPSTREAM_TIP" "$new_head"; then
  echo "error: created commit $new_head failed the exact tree, ref, or two-parent ancestry proof; stop and inspect it" >&2
  exit 1
fi

echo "upstream-sync: created merge $new_head"
echo "upstream-sync: first parent (fork) $first_parent"
echo "upstream-sync: second parent (upstream) $second_parent"
echo "upstream-sync: verified both tips are ancestors; push and pull-request actions remain manual"
