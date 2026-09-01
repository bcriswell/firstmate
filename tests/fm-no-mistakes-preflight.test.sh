#!/usr/bin/env bash
# Regression tests for the no-mistakes structured-attestation version preflight.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PREFLIGHT="$ROOT/bin/fm-no-mistakes-preflight.sh"
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-preflight)

run_with_version() {
  local version=$1 fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT/$version")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$FM_TEST_NO_MISTAKES_VERSION"
SH
  chmod +x "$fakebin/no-mistakes"
  FM_TEST_NO_MISTAKES_VERSION="$version" PATH="$fakebin:$PATH" "$PREFLIGHT" 2>&1
}

required=$($PREFLIGHT --required-version) || fail "preflight did not report its version floor"
[ "$required" = 1.46.0 ] || fail "unexpected no-mistakes version floor: $required"
pass "preflight reports the structured-attestation version floor"

run_with_version 'no-mistakes version v1.46.0 (fake)' >/dev/null \
  || fail "preflight rejected the first attestation-capable no-mistakes release"
run_with_version 'no-mistakes version v1.60.2 (fake)' >/dev/null \
  || fail "preflight rejected a newer no-mistakes release"
pass "preflight accepts the floor and newer clients"

rc=0
out=$(run_with_version 'no-mistakes version v1.41.2 (fake)') || rc=$?
[ "$rc" -eq 1 ] || fail "preflight accepted the legacy client that produced an unattested PR body"
assert_contains "$out" "1.46.0 or newer" "legacy-client refusal omitted the required version"
assert_contains "$out" "v1.41.2" "legacy-client refusal omitted the installed version"
assert_contains "$out" "structured pipeline attestation" "legacy-client refusal omitted the reason"
pass "preflight rejects clients that cannot publish structured attestation"

rc=0
out=$(run_with_version 'development build') || rc=$?
[ "$rc" -eq 1 ] || fail "preflight accepted an unparseable development version"
assert_contains "$out" "development build" "unparseable-version refusal omitted the observed output"
pass "preflight fails closed on an unparseable client version"

assert_grep "lint: 'bin/fm-no-mistakes-preflight.sh && bin/fm-lint.sh'" "$ROOT/.no-mistakes.yaml" \
  "the gate lint command does not run the attestation preflight before lint"
pass "the no-mistakes gate runs the version preflight before lint"
