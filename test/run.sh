#!/usr/bin/env bash
# Self-test for pr-rules.sh: every fixture declares the outcome it must produce.
# Run: bash test/run.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../rules/pr-rules.sh"
FIX="$HERE/fixtures"
PASS=0
FAIL=0

# name | expected exit | base | head | draft | diff
run_case() {
  local name="$1" want="$2" base="$3" head="$4" draft="$5" diff="$6"
  local out rc
  out=$(BASE_REF="$base" HEAD_REF="$head" HEAD_REPO="Anxiety471/pnrs" BASE_REPO="Anxiety471/pnrs" \
    PR_DRAFT="$draft" PR_TITLE="fix: small thing" \
    PR_RULES_DIFF="$FIX/$diff" \
    bash "$SCRIPT" 2>&1)
  rc=$?
  if [ "$rc" -eq "$want" ]; then
    printf '  PASS  %-22s exit %s\n' "$name" "$rc"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  %-22s exit %s, wanted %s\n' "$name" "$rc" "$want"
    printf '%s\n' "$out" | sed 's/^/          | /'
    FAIL=$((FAIL + 1))
  fi
}

echo "pr-rules self-test"
run_case clean               0 staging feat/census-module false clean.diff
run_case aws-key             1 staging feat/census-module false aws-key.diff
run_case private-key         1 staging fix/dtr-rounding   false private-key.diff
run_case allowlisted-key     0 staging fix/dtr-rounding   false allowlisted-key.diff
run_case vendored-skip       0 staging fix/dtr-rounding   false vendored.diff
run_case bad-branch-name     1 staging mywork            false clean.diff
run_case draft               1 staging feat/census-module true  clean.diff
run_case direct-to-main      1 main    feat/census-module false clean.diff
run_case promote-staging     0 main    staging            false clean.diff
run_case hardcoded-password  1 staging fix/dtr-rounding   false hardcoded-password.diff
run_case placeholder-ok      0 staging fix/dtr-rounding   false placeholder.diff
run_case jwt                 1 staging fix/dtr-rounding   false jwt.diff
run_case github-token        1 staging fix/dtr-rounding   false github-token.diff

echo
echo "self-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]