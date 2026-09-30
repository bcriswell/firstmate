#!/usr/bin/env bash
# Check the live relationship between the bcriswell/firstmate fork and the
# kunchenguid/firstmate upstream without changing a local branch.
#
# The check is dedicated to these repositories and requires the exact remotes:
#   origin   https://github.com/bcriswell/firstmate.git
#   upstream https://github.com/kunchenguid/firstmate.git
# Both live remote HEADs must name main. The command reads each live HEAD with a
# bounded ls-remote call, fetches that exact main ref without tags, and requires
# the fetched tracking ref to equal the advertised commit. It refuses shallow or
# partial history, rewritten tracking refs, unexpected remote configuration,
# unavailable network/authentication, a remote that moves during the check, and
# ancestry with no single merge base.
#
# A successful check prints both tips and exactly one relationship:
#   no-drift             the tips are identical
#   upstream-behind-fork upstream/main is an ancestor of origin/main
#   fork-behind-upstream origin/main is an ancestor of upstream/main
#   divergence           both remotes have commits after their merge base
# Exit 0 means a complete classification was produced; exit 1 means no
# relationship is safe to consume. --result atomically writes the stable
# fm-upstream-drift-v1 key/value record consumed by fm-upstream-sync.sh. The
# record is bound to the physical repository, exact URLs/default branches,
# object format, both commit identities, merge base, and relationship. It has no
# timestamp, so an unchanged repeated check is byte-identical.
#
# Network calls are hard-bounded to 60 seconds by default. Set
# FM_UPSTREAM_SYNC_TIMEOUT to another positive integer number of seconds.
#
# Usage: fm-upstream-drift.sh [--repo <path>] [--result <path>] [--help]
# Example:
#   bin/fm-upstream-drift.sh --result state/upstream-drift.result
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

EXPECTED_ORIGIN_URL=https://github.com/bcriswell/firstmate.git
EXPECTED_UPSTREAM_URL=https://github.com/kunchenguid/firstmate.git
EXPECTED_DEFAULT=main
NETWORK_TIMEOUT=${FM_UPSTREAM_SYNC_TIMEOUT:-60}
REPO=.
RESULT=

usage() {
  cat <<'EOF'
usage: fm-upstream-drift.sh [--repo <path>] [--result <path>] [--help]

Refresh and classify the live origin/main and upstream/main relationship for:
  origin   https://github.com/bcriswell/firstmate.git
  upstream https://github.com/kunchenguid/firstmate.git

Options:
  --repo <path>    Repository to inspect (default: current directory).
  --result <path>  Atomically write an fm-upstream-drift-v1 result for
                   fm-upstream-sync.sh. An unchanged rerun is byte-identical.
  -h, --help       Show this help.

Relationships:
  no-drift             Both tips are identical.
  upstream-behind-fork upstream/main is already contained in the fork.
  fork-behind-upstream The fork tip is an ancestor of upstream/main.
  divergence           Both sides have commits after one merge base.

Exit status:
  0  The live tips were fetched, history was complete, and one relationship was
     reported (and written when --result was supplied).
  1  The result is unsafe or unavailable; diagnostics name the failed guard.

The check never changes a local branch or worktree file. It does update the two
remote-tracking refs after proving the configured URLs and live default branches.
Network calls are bounded by FM_UPSTREAM_SYNC_TIMEOUT (default 60 seconds).
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

case "$NETWORK_TIMEOUT" in
  ''|*[!0-9]*|0)
    echo "error: FM_UPSTREAM_SYNC_TIMEOUT must be a positive integer (got '$NETWORK_TIMEOUT')" >&2
    exit 1
    ;;
esac

REPO=$(cd -- "$REPO" 2>/dev/null && pwd -P) || {
  echo "error: repository path '$REPO' is not an accessible directory" >&2
  exit 1
}
case "$REPO" in
  *$'\n'*|*$'\r'*)
    echo "error: repository path is not representable in an fm-upstream-drift-v1 result" >&2
    exit 1
    ;;
esac

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

if [ "$(git -C "$REPO" rev-parse --is-shallow-repository 2>/dev/null || echo unknown)" != false ]; then
  echo "error: repository history is shallow or its completeness cannot be proved; fetch complete history before checking drift" >&2
  exit 1
fi
if git -C "$REPO" config --get-regexp '^remote\..*\.promisor$' 2>/dev/null \
  | grep -Eq '[[:space:]]true$'; then
  echo "error: repository uses a partial/promisor remote; complete ancestry cannot be proved" >&2
  exit 1
fi

grafts=$(git -C "$REPO" rev-parse --git-path info/grafts 2>/dev/null || true)
if [ -n "$grafts" ] && [ -s "$grafts" ]; then
  echo "error: repository has legacy grafts at '$grafts'; unmodified ancestry cannot be proved" >&2
  exit 1
fi
if git -C "$REPO" for-each-ref --format='%(refname)' refs/replace 2>/dev/null | grep -q .; then
  echo "error: repository has replacement refs; unmodified ancestry cannot be proved" >&2
  exit 1
fi

remote_raw_url() {  # <remote>
  git -C "$REPO" config --get-all "remote.$1.url" 2>/dev/null || true
}

verify_remote_url() {  # <remote> <expected-url>
  local remote=$1 expected=$2 urls push_urls
  urls=$(remote_raw_url "$remote")
  case "$urls" in
    "$expected") ;;
    '')
      echo "error: required remote '$remote' is missing" >&2
      return 1
      ;;
    *)
      echo "error: remote '$remote' must have exactly URL '$expected' (configured: $(printf '%s' "$urls" | tr '\n' ' '))" >&2
      return 1
      ;;
  esac
  push_urls=$(git -C "$REPO" config --get-all "remote.$remote.pushurl" 2>/dev/null || true)
  case "$push_urls" in
    ''|"$expected") ;;
    *)
      echo "error: remote '$remote' has an unexpected push URL (expected '$expected', configured: $(printf '%s' "$push_urls" | tr '\n' ' '))" >&2
      return 1
      ;;
  esac
}

verify_remote_url origin "$EXPECTED_ORIGIN_URL" || exit 1
verify_remote_url upstream "$EXPECTED_UPSTREAM_URL" || exit 1

remote_advertisement() {  # <remote>
  local remote=$1 output rc branch head_tip branch_tip
  if output=$(fm_run_timed "$NETWORK_TIMEOUT" git -C "$REPO" ls-remote --symref "$remote" HEAD "refs/heads/$EXPECTED_DEFAULT" 2>&1); then
    :
  else
    rc=$?
    if [ "$rc" -eq 124 ]; then
      echo "error: timed out after ${NETWORK_TIMEOUT}s while reading live '$remote' refs" >&2
    else
      echo "error: could not read live '$remote' refs (network or authentication failure, exit $rc)" >&2
    fi
    [ -z "$output" ] || printf '%s\n' "$output" >&2
    return 1
  fi
  branch=$(printf '%s\n' "$output" | awk '$1 == "ref:" && $3 == "HEAD" { sub(/^refs\/heads\//, "", $2); print $2 }')
  head_tip=$(printf '%s\n' "$output" | awk '$2 == "HEAD" && $1 != "ref:" { print $1 }')
  branch_tip=$(printf '%s\n' "$output" | awk -v ref="refs/heads/$EXPECTED_DEFAULT" '$1 != "ref:" && $2 == ref { print $1 }')
  case "$branch" in
    "$EXPECTED_DEFAULT") ;;
    ''|*$'\n'*)
      echo "error: remote '$remote' did not advertise one unambiguous default branch" >&2
      return 1
      ;;
    *)
      echo "error: remote '$remote' default branch is '$branch', expected '$EXPECTED_DEFAULT'" >&2
      return 1
      ;;
  esac
  case "$head_tip" in
    ''|*$'\n'*)
      echo "error: remote '$remote' did not advertise one unambiguous HEAD commit" >&2
      return 1
      ;;
  esac
  case "$branch_tip" in
    ''|*$'\n'*)
      echo "error: remote '$remote' did not advertise one unambiguous refs/heads/$EXPECTED_DEFAULT commit" >&2
      return 1
      ;;
  esac
  [ "$head_tip" = "$branch_tip" ] || {
    echo "error: remote '$remote' HEAD ($head_tip) does not match refs/heads/$EXPECTED_DEFAULT ($branch_tip)" >&2
    return 1
  }
  printf '%s\n' "$head_tip"
}

fetch_verified_tip() {  # <remote> <advertised-tip>
  local remote=$1 advertised=$2 output rc fetched normalized
  if output=$(fm_run_timed "$NETWORK_TIMEOUT" git -C "$REPO" fetch --no-tags "$remote" \
      "refs/heads/$EXPECTED_DEFAULT:refs/remotes/$remote/$EXPECTED_DEFAULT" 2>&1); then
    :
  else
    rc=$?
    if [ "$rc" -eq 124 ]; then
      echo "error: timed out after ${NETWORK_TIMEOUT}s while fetching '$remote/$EXPECTED_DEFAULT'" >&2
    else
      echo "error: could not fetch '$remote/$EXPECTED_DEFAULT' without rewriting its tracking ref (network, authentication, or rewritten-history failure; exit $rc)" >&2
    fi
    [ -z "$output" ] || printf '%s\n' "$output" >&2
    return 1
  fi
  fetched=$(git -C "$REPO" rev-parse --verify "refs/remotes/$remote/$EXPECTED_DEFAULT^{commit}" 2>/dev/null) || {
    echo "error: fetched '$remote/$EXPECTED_DEFAULT' is not a commit" >&2
    return 1
  }
  normalized=$(git -C "$REPO" rev-parse --verify "$advertised^{commit}" 2>/dev/null) || {
    echo "error: advertised '$remote/$EXPECTED_DEFAULT' commit '$advertised' is unavailable after fetch" >&2
    return 1
  }
  [ "$normalized" = "$advertised" ] || {
    echo "error: remote '$remote/$EXPECTED_DEFAULT' advertised non-canonical commit '$advertised'" >&2
    return 1
  }
  [ "$fetched" = "$advertised" ] || {
    echo "error: remote '$remote/$EXPECTED_DEFAULT' moved during the drift check (advertised $advertised, fetched $fetched); retry" >&2
    return 1
  }
  printf '%s\n' "$fetched"
}

origin_advertised=$(remote_advertisement origin) || exit 1
upstream_advertised=$(remote_advertisement upstream) || exit 1
origin_tip=$(fetch_verified_tip origin "$origin_advertised") || exit 1
upstream_tip=$(fetch_verified_tip upstream "$upstream_advertised") || exit 1

merge_base=$(GIT_NO_REPLACE_OBJECTS=1 git -C "$REPO" merge-base --all "$origin_tip" "$upstream_tip" 2>/dev/null || true)
case "$merge_base" in
  ''|*$'\n'*)
    echo "error: origin/main and upstream/main do not have one unambiguous merge base; ancestry may be unrelated or incomplete" >&2
    exit 1
    ;;
esac

if [ "$origin_tip" = "$upstream_tip" ]; then
  relationship=no-drift
elif GIT_NO_REPLACE_OBJECTS=1 git -C "$REPO" merge-base --is-ancestor "$upstream_tip" "$origin_tip"; then
  relationship=upstream-behind-fork
elif GIT_NO_REPLACE_OBJECTS=1 git -C "$REPO" merge-base --is-ancestor "$origin_tip" "$upstream_tip"; then
  relationship=fork-behind-upstream
else
  relationship=divergence
fi

object_format=$(git -C "$REPO" config --get extensions.objectFormat 2>/dev/null || true)
object_format=${object_format:-sha1}
case "$object_format" in sha1|sha256) ;; *)
  echo "error: unsupported Git object format '$object_format'" >&2
  exit 1
  ;;
esac

if [ -n "$RESULT" ]; then
  result_dir=$(dirname -- "$RESULT")
  [ -d "$result_dir" ] || {
    echo "error: result directory '$result_dir' does not exist" >&2
    exit 1
  }
  result_tmp=$(mktemp "$result_dir/.fm-upstream-drift.XXXXXX") || {
    echo "error: could not create a temporary result in '$result_dir'" >&2
    exit 1
  }
  trap 'rm -f "$result_tmp"' EXIT
  {
    printf 'format=fm-upstream-drift-v1\n'
    printf 'repository=%s\n' "$REPO"
    printf 'object_format=%s\n' "$object_format"
    printf 'origin_url=%s\n' "$EXPECTED_ORIGIN_URL"
    printf 'origin_default=%s\n' "$EXPECTED_DEFAULT"
    printf 'origin_tip=%s\n' "$origin_tip"
    printf 'upstream_url=%s\n' "$EXPECTED_UPSTREAM_URL"
    printf 'upstream_default=%s\n' "$EXPECTED_DEFAULT"
    printf 'upstream_tip=%s\n' "$upstream_tip"
    printf 'merge_base=%s\n' "$merge_base"
    printf 'relationship=%s\n' "$relationship"
  } > "$result_tmp"
  chmod 600 "$result_tmp"
  mv -f -- "$result_tmp" "$RESULT"
  trap - EXIT
fi

printf 'upstream-drift: fork origin/%s %s\n' "$EXPECTED_DEFAULT" "$origin_tip"
printf 'upstream-drift: original upstream/%s %s\n' "$EXPECTED_DEFAULT" "$upstream_tip"
printf 'upstream-drift: merge base %s\n' "$merge_base"
printf 'upstream-drift: relationship %s\n' "$relationship"
[ -z "$RESULT" ] || printf 'upstream-drift: result %s\n' "$RESULT"
