#!/usr/bin/env bash
# pr-rules.sh - house rules for pull requests. Exit 1 blocks the PR.
#
# Reads its inputs from the environment (set by rules/action.yml).
# No GitHub API calls: everything comes from the event payload and the diff,
# so the caller needs no token beyond the checkout it already does.
#
# Test hook: set PR_RULES_DIFF to a unified diff file and the git step is skipped.
set -uo pipefail

FAILS=0
WARNS=0

fail() { printf '::error title=PR rules::%s\n' "$*"; FAILS=$((FAILS + 1)); }
warn() { printf '::warning title=PR rules::%s\n' "$*"; WARNS=$((WARNS + 1)); }
ok()   { printf '  ok    %s\n' "$*"; }
skip() { printf '  skip  %s\n' "$*"; }

BASE_REF="${BASE_REF:-main}"
HEAD_REF="${HEAD_REF:-}"
HEAD_REPO="${HEAD_REPO:-}"
BASE_REPO="${BASE_REPO:-}"
PR_DRAFT="${PR_DRAFT:-false}"
PR_BODY="${PR_BODY:-}"

STAGING_BRANCH="${INPUT_STAGING_BRANCH:-staging}"
MAIN_BRANCH="${INPUT_MAIN_BRANCH:-main}"
REQUIRE_STAGING="${INPUT_REQUIRE_STAGING_FLOW:-true}"
BRANCH_PATTERN="${INPUT_BRANCH_PATTERN:-}"
ALLOW_DRAFT="${INPUT_ALLOW_DRAFT:-false}"
SCAN_SECRETS="${INPUT_SCAN_SECRETS:-true}"
REQUIRE_ISSUE="${INPUT_REQUIRE_ISSUE_REFERENCE:-false}"
MAX_TITLE_LEN="${INPUT_MAX_TITLE_LENGTH:-72}"

echo "pr-rules: ${HEAD_REF:-?} -> ${BASE_REF:-?} (draft=${PR_DRAFT})"
echo

# ---------------------------------------------------------------- 1. staging flow
if [ "$REQUIRE_STAGING" = "true" ] && [ "$BASE_REF" = "$MAIN_BRANCH" ]; then
  if [ "$HEAD_REF" = "$STAGING_BRANCH" ] && [ "$HEAD_REPO" = "$BASE_REPO" ]; then
    ok "only ${STAGING_BRANCH} merges into ${MAIN_BRANCH}"
  else
    fail "PRs into ${MAIN_BRANCH} must come from ${STAGING_BRANCH} in this repository (got '${HEAD_REF}' from '${HEAD_REPO:-unknown}'). Open the PR against ${STAGING_BRANCH}, then promote it."
  fi
else
  skip "staging-flow check (base is ${BASE_REF}, not ${MAIN_BRANCH})"
fi

# ---------------------------------------------------------------- 2. branch name
DEFAULT_PATTERN='^(staging|main|(feat|feature|fix|bugfix|hotfix|chore|docs|refactor|test|perf|build|ci|release|deps)/[A-Za-z0-9._/-]+|claude/[A-Za-z0-9._-]+|dependabot/[A-Za-z0-9._/-]+)$'
PATTERN="${BRANCH_PATTERN:-$DEFAULT_PATTERN}"
if [ -z "$HEAD_REF" ]; then
  skip "branch name (no head ref in the event)"
elif printf '%s' "$HEAD_REF" | grep -Eq "$PATTERN"; then
  ok "branch name '${HEAD_REF}'"
else
  fail "branch name '${HEAD_REF}' does not match the house pattern. Use <type>/<slug>, e.g. fix/dtr-rounding or feat/census-module."
fi

# ---------------------------------------------------------------- 3. draft
if [ "$ALLOW_DRAFT" = "true" ]; then
  skip "draft check (allow-draft is true)"
elif [ "$PR_DRAFT" = "true" ]; then
  fail "this PR is a draft. The house rule is ready-for-review PRs; mark it ready when CI is green."
else
  ok "PR is ready for review, not a draft"
fi

# ---------------------------------------------------------------- 4. title
TITLE="${PR_TITLE:-}"
if [ -z "$TITLE" ]; then
  skip "title length (no title in the event)"
elif [ "${#TITLE}" -gt "$MAX_TITLE_LEN" ]; then
  warn "PR title is ${#TITLE} characters (soft limit ${MAX_TITLE_LEN}); long titles are truncated in the UI and in release notes."
else
  ok "title is ${#TITLE} characters"
fi

# ---------------------------------------------------------------- 5. issue reference
if [ "$REQUIRE_ISSUE" = "true" ]; then
  if printf '%s' "$TITLE $PR_BODY" | grep -Eq '(#[0-9]+|\b[A-Z][A-Z0-9]+-[0-9]+\b)'; then
    ok "PR references an issue"
  else
    fail "PR must reference its issue (a GitHub number like #123 or a tracker key like HIT-123) in the title or body."
  fi
else
  skip "issue reference (opt-in via require-issue-reference)"
fi

# ---------------------------------------------------------------- 6. secrets in the diff
DIFF_FILE="${PR_RULES_DIFF:-}"
TMP_DIFF=""
cleanup() { [ -n "$TMP_DIFF" ] && rm -f "$TMP_DIFF"; }
trap cleanup EXIT

if [ "$SCAN_SECRETS" != "true" ]; then
  skip "secret scan (disabled)"
else
  if [ -z "$DIFF_FILE" ]; then
    TMP_DIFF="$(mktemp)"
    DIFF_FILE="$TMP_DIFF"
    if git rev-parse --git-dir >/dev/null 2>&1 && git rev-parse --verify -q "origin/${BASE_REF}" >/dev/null 2>&1; then
      git diff --unified=0 "origin/${BASE_REF}...HEAD" >"$DIFF_FILE" 2>/dev/null || : >"$DIFF_FILE"
    else
      : >"$DIFF_FILE"
    fi
  fi

  # added lines only, with real file:line, skipping vendored and generated files
  ADDED="$(mktemp)"
  awk '
    /^\+\+\+ / { file = $2; sub(/^b\//, "", file); next }
    /^@@ / { match($0, /\+[0-9]+/); nline = substr($0, RSTART + 1, RLENGTH - 1) + 0; next }
    /^\+/ {
      if (nline == "") next
      path = file
      if (path ~ /(^|\/)(vendor|node_modules)\//) next
      if (path ~ /\.(lock|map|min\.js|min\.css|snap)$/) next
      if (path ~ /(^|\/)(package-lock\.json|bun\.lock|composer\.lock|yarn\.lock)$/) next
      line = substr($0, 2)
      if (line ~ /pr-rules:(allow|ignore)/) next
      print path ":" nline ":" line
      nline++
      next
    }
    /^ / { if (nline != "") nline++ }
  ' "$DIFF_FILE" >"$ADDED"

  if [ ! -s "$ADDED" ]; then
    ok "no added lines to scan"
  else
    # pattern|label
    PATTERNS=$(cat <<'PATTERNS_END'
AKIA[0-9A-Z]{16}|AWS access key id
ASIA[0-9A-Z]{16}|AWS temporary access key id
gh[pousr]_[A-Za-z0-9]{36,}|GitHub token
github_pat_[A-Za-z0-9_]{22,}|GitHub fine-grained token
xox[baprs]-[0-9A-Za-z-]{10,}|Slack token
AIza[0-9A-Za-z_-]{35}|Google API key
sk-[A-Za-z0-9]{32,}|API secret key (sk-)
-----BEGIN [A-Z ]*PRIVATE KEY-----|private key block
eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|JSON web token
PATTERNS_END
)
    HITS=0
    while IFS='|' read -r rx label; do
      [ -z "$rx" ] && continue
      while IFS= read -r hit; do
        [ -z "$hit" ] && continue
        fail "possible ${label} added at ${hit%%:*}:$(printf '%s' "$hit" | cut -d: -f2). Remove it, rotate the credential, and use a repository secret. False positive? Append 'pr-rules:allow' to the line."
        HITS=$((HITS + 1))
      done < <(grep -E -- "$rx" "$ADDED" || true)
    done <<<"$PATTERNS"

    # assignment-shaped secrets, case-insensitive, with obvious placeholders ignored
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      rest="${hit#*:*:}"
      shopt -s nocasematch
      case "$rest" in
        *changeme*|*change-me*|*placeholder*|*example*|*your_*|*your-*|*dummy*|*xxx*|*'${'*|*'<'*'>'*|*redacted*|*'***'*) shopt -u nocasematch; continue ;;
      esac
      shopt -u nocasematch
      fail "possible hardcoded credential at ${hit%%:*}:$(printf '%s' "$hit" | cut -d: -f2). Move it to a repository secret. False positive? Append 'pr-rules:allow' to the line."
      HITS=$((HITS + 1))
    done < <(grep -Ei -- '(password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{8,}' "$ADDED" || true)

    if [ "$HITS" -eq 0 ]; then
      ok "no credentials in $(wc -l <"$ADDED") added line(s)"
    fi
    rm -f "$ADDED"
  fi
fi

# ---------------------------------------------------------------- summary
echo
if [ "$FAILS" -gt 0 ]; then
  echo "pr-rules: ${FAILS} blocking problem(s), ${WARNS} warning(s)."
  exit 1
fi
if [ "$WARNS" -gt 0 ]; then
  echo "pr-rules: all checks passed ($WARNS warning(s))."
else
  echo "pr-rules: all checks passed."
fi