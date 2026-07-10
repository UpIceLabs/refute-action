#!/usr/bin/env bash
# Test matrix for the /refute action entrypoint. Plain bash, no framework.
# Block case exit=1, pass cases exit=0, summary + ledger content asserted.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ENTRY="$HERE/../entrypoint.sh"
SEP='-----8<-----'

pass=0; failc=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then pass=$((pass+1)); else failc=$((failc+1)); echo "FAIL: $1 (expected $2, got $3)"; fi
}

run() { # exports set by caller; returns exit code
  TMP="$(mktemp -d)"
  GITHUB_STEP_SUMMARY="$TMP/summary.md" GITHUB_OUTPUT="$TMP/out.txt" RUNNER_TEMP="$TMP" \
    GITHUB_EVENT_PATH="" GITHUB_BASE_REF="" "$ENTRY" >/dev/null 2>&1
  echo $?
}

# 1. BLOCK: done-claim in PR body, no evidence, no test diff -> exit 1
export REFUTE_PR_BODY="fix: calculator done, all tests pass"
export REFUTE_COMMIT_MSGS="" REFUTE_CHANGED_FILES="" REFUTE_LEDGER=false
check "block: claim w/o evidence" 1 "$(run)"

# 2. PASS: Evidence line in PR body -> exit 0
export REFUTE_PR_BODY="fix: calculator done. Evidence: pytest -q -> 12 passed"
check "pass: Evidence line" 0 "$(run)"

# 3. PASS: claim + test-file diff -> exit 0
export REFUTE_PR_BODY="fixed the rounding bug"
export REFUTE_CHANGED_FILES=$'src/calc.py\ntests/test_calc.py'
check "pass: test diff" 0 "$(run)"

# 4. PASS: no claims at all -> exit 0
export REFUTE_PR_BODY="refactor: rename variables" REFUTE_CHANGED_FILES=""
check "pass: no claims" 0 "$(run)"

# 5. BLOCK: claim hides in a commit message, PR body clean -> exit 1
export REFUTE_PR_BODY="refactor: misc"
export REFUTE_COMMIT_MSGS="works now, ship it
$SEP
chore: bump version"
check "block: claim in commit msg" 1 "$(run)"

# 6. scan-commits=false ignores commit-message claims -> exit 0
export REFUTE_SCAN_COMMITS=false
check "pass: scan-commits off" 0 "$(run)"
unset REFUTE_SCAN_COMMITS

# 7. Custom claim-words: default word passes, custom word blocks
export REFUTE_COMMIT_MSGS="" REFUTE_PR_BODY="shipped the feature"
check "pass: 'shipped' not default claim word" 0 "$(run)"
export REFUTE_CLAIM_WORDS="shipped,deployed"
check "block: custom claim word" 1 "$(run)"
unset REFUTE_CLAIM_WORDS

# 8. Summary contains the fix instructions + verdict grammar on block
TMP="$(mktemp -d)"
REFUTE_PR_BODY="done" REFUTE_COMMIT_MSGS="" REFUTE_CHANGED_FILES="" \
GITHUB_STEP_SUMMARY="$TMP/summary.md" GITHUB_OUTPUT="$TMP/out.txt" RUNNER_TEMP="$TMP" \
GITHUB_EVENT_PATH="" GITHUB_BASE_REF="" "$ENTRY" >/dev/null 2>&1
if grep -q 'Evidence: <command you ran>' "$TMP/summary.md" \
   && grep -q 'REFUTE | UNVERIFIED' "$TMP/summary.md" \
   && grep -q 'verdict=UNVERIFIED' "$TMP/out.txt"; then
  pass=$((pass+1))
else
  failc=$((failc+1)); echo "FAIL: summary fix-instructions + grammar + output"
fi

# 9. ledger=true writes a REFUTE line to the artifact staging path
TMP="$(mktemp -d)"
REFUTE_PR_BODY="fixed it. Evidence: make test -> ok" REFUTE_COMMIT_MSGS="" REFUTE_CHANGED_FILES="" \
REFUTE_LEDGER=true \
GITHUB_STEP_SUMMARY="$TMP/summary.md" GITHUB_OUTPUT="$TMP/out.txt" RUNNER_TEMP="$TMP" \
GITHUB_EVENT_PATH="" GITHUB_BASE_REF="" "$ENTRY" >/dev/null 2>&1
if grep -q '| REFUTE | CONFIRMED' "$TMP/refute-ledger/verdicts.log" 2>/dev/null; then
  pass=$((pass+1))
else
  failc=$((failc+1)); echo "FAIL: ledger fragment written"
fi

# 10. ledger=false writes nothing
TMP="$(mktemp -d)"
REFUTE_PR_BODY="no claims here" REFUTE_LEDGER=false \
GITHUB_STEP_SUMMARY="$TMP/summary.md" GITHUB_OUTPUT="$TMP/out.txt" RUNNER_TEMP="$TMP" \
GITHUB_EVENT_PATH="" GITHUB_BASE_REF="" "$ENTRY" >/dev/null 2>&1
if [ ! -e "$TMP/refute-ledger/verdicts.log" ]; then
  pass=$((pass+1))
else
  failc=$((failc+1)); echo "FAIL: ledger off writes nothing"
fi

# 11. scan-reviews=true + LGTM approval on unverified claim -> summary note, still exit 1
TMP="$(mktemp -d)"
REFUTE_PR_BODY="fixed it, done" REFUTE_COMMIT_MSGS="" REFUTE_CHANGED_FILES="" REFUTE_LEDGER=false \
REFUTE_SCAN_REVIEWS=true REFUTE_REVIEW_BODIES='[{"state":"APPROVED","body":"LGTM, ship it"}]' \
GITHUB_STEP_SUMMARY="$TMP/summary.md" GITHUB_OUTPUT="$TMP/out.txt" RUNNER_TEMP="$TMP" \
GITHUB_EVENT_PATH="" GITHUB_BASE_REF="" "$ENTRY" >/dev/null 2>&1
rc=$?
if [ "$rc" = 1 ] && grep -q 'approvals on unverified claims' "$TMP/summary.md" \
   && grep -q 'never fails the check' "$TMP/summary.md"; then
  pass=$((pass+1))
else
  failc=$((failc+1)); echo "FAIL: scan-reviews LGTM note (rc=$rc)"
fi

# 12. scan-reviews default (false): identical inputs, no note
TMP="$(mktemp -d)"
REFUTE_PR_BODY="fixed it, done" REFUTE_COMMIT_MSGS="" REFUTE_CHANGED_FILES="" REFUTE_LEDGER=false \
REFUTE_REVIEW_BODIES='[{"state":"APPROVED","body":"LGTM"}]' \
GITHUB_STEP_SUMMARY="$TMP/summary.md" GITHUB_OUTPUT="$TMP/out.txt" RUNNER_TEMP="$TMP" \
GITHUB_EVENT_PATH="" GITHUB_BASE_REF="" "$ENTRY" >/dev/null 2>&1
if ! grep -q 'approvals on unverified claims' "$TMP/summary.md"; then
  pass=$((pass+1))
else
  failc=$((failc+1)); echo "FAIL: scan-reviews off by default"
fi

# 13. scan-reviews=true, mocked gh api call (PR number from event, token set)
TMP="$(mktemp -d)"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# mock gh: assert the reviews endpoint was asked for, emit one approval
case "$*" in
  *"pulls/42/reviews"*) echo '[{"state":"APPROVED","body":"looks good to me!"}]' ;;
  *) echo "mock gh: unexpected args: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
echo '{"pull_request":{"number":42}}' > "$TMP/event.json"
REFUTE_PR_BODY="works now" REFUTE_COMMIT_MSGS="" REFUTE_CHANGED_FILES="" REFUTE_LEDGER=false \
REFUTE_SCAN_REVIEWS=true REFUTE_REVIEW_BODIES="" \
PATH="$TMP/bin:$PATH" GITHUB_TOKEN=fake-token GITHUB_REPOSITORY=acme/widgets \
GITHUB_STEP_SUMMARY="$TMP/summary.md" GITHUB_OUTPUT="$TMP/out.txt" RUNNER_TEMP="$TMP" \
GITHUB_EVENT_PATH="$TMP/event.json" GITHUB_BASE_REF="" "$ENTRY" >/dev/null 2>&1
rc=$?
if [ "$rc" = 1 ] && grep -q 'looks good to me' "$TMP/summary.md"; then
  pass=$((pass+1))
else
  failc=$((failc+1)); echo "FAIL: scan-reviews via mocked gh (rc=$rc)"
fi

# 14. scan-reviews=true but no token/gh/PR -> graceful skip, exit code unchanged
TMP="$(mktemp -d)"
REFUTE_PR_BODY="fixed it" REFUTE_COMMIT_MSGS="" REFUTE_CHANGED_FILES="" REFUTE_LEDGER=false \
REFUTE_SCAN_REVIEWS=true REFUTE_REVIEW_BODIES="" GITHUB_TOKEN="" \
GITHUB_STEP_SUMMARY="$TMP/summary.md" GITHUB_OUTPUT="$TMP/out.txt" RUNNER_TEMP="$TMP" \
GITHUB_EVENT_PATH="" GITHUB_BASE_REF="" "$ENTRY" >/dev/null 2>"$TMP/err.txt"
rc=$?
if [ "$rc" = 1 ] && grep -q 'skipped' "$TMP/err.txt" \
   && ! grep -q 'approvals on unverified claims' "$TMP/summary.md"; then
  pass=$((pass+1))
else
  failc=$((failc+1)); echo "FAIL: scan-reviews graceful skip (rc=$rc)"
fi

# 15. HELPFUL MODE: unverified claim + injected CI command -> pre-filled
#     Evidence: template using that command appears in the summary.
TMP="$(mktemp -d)"
REFUTE_PR_BODY="fixed the calc bug" REFUTE_COMMIT_MSGS="" \
REFUTE_CHANGED_FILES=$'src/calc.py\nsrc/util.py' REFUTE_LEDGER=false \
REFUTE_CI_COMMANDS="pytest tests/ -q" \
GITHUB_STEP_SUMMARY="$TMP/summary.md" GITHUB_OUTPUT="$TMP/out.txt" RUNNER_TEMP="$TMP" \
GITHUB_EVENT_PATH="" GITHUB_BASE_REF="" "$ENTRY" >/dev/null 2>&1
rc=$?
if [ "$rc" = 1 ] && grep -q 'Pre-filled evidence template' "$TMP/summary.md" \
   && grep -q 'Evidence: pytest tests/ -q ->' "$TMP/summary.md"; then
  pass=$((pass+1))
else
  failc=$((failc+1)); echo "FAIL: helpful mode pre-filled template (rc=$rc)"
fi

# 16. HELPFUL MODE: template lists the changed SOURCE files (non-test) as
#     "likely need a test", so the Action teaches what's missing.
if grep -q '`src/calc.py`' "$TMP/summary.md" \
   && grep -q 'likely need a test' "$TMP/summary.md"; then
  pass=$((pass+1))
else
  failc=$((failc+1)); echo "FAIL: helpful mode lists source files"
fi

# 17. HELPFUL MODE: real CI detection from a .github/workflows file on disk
#     (no REFUTE_CI_COMMANDS override) -> detected command shows its source.
TMP="$(mktemp -d)"; mkdir -p "$TMP/repo/.github/workflows"
cat > "$TMP/repo/.github/workflows/ci.yml" <<'EOF'
jobs:
  test:
    steps:
      - run: pytest tests/ --cov
EOF
( cd "$TMP/repo" && \
  REFUTE_PR_BODY="done, resolved the parser" REFUTE_COMMIT_MSGS="" \
  REFUTE_CHANGED_FILES="src/parser.py" REFUTE_LEDGER=false REFUTE_CI_COMMANDS="" \
  GITHUB_STEP_SUMMARY="$TMP/summary.md" GITHUB_OUTPUT="$TMP/out.txt" RUNNER_TEMP="$TMP" \
  GITHUB_EVENT_PATH="" GITHUB_BASE_REF="" "$ENTRY" >/dev/null 2>&1 )
if grep -q 'from ci.yml' "$TMP/summary.md" \
   && grep -Eq 'pytest tests/' "$TMP/summary.md"; then
  pass=$((pass+1))
else
  failc=$((failc+1)); echo "FAIL: helpful mode detects CI command from workflow file"
fi

# 18. HELPFUL MODE off-path: a CONFIRMED claim gets NO template (nothing to teach)
TMP="$(mktemp -d)"
REFUTE_PR_BODY="fixed it. Evidence: pytest -> 9 passed" REFUTE_COMMIT_MSGS="" \
REFUTE_CHANGED_FILES="" REFUTE_LEDGER=false REFUTE_CI_COMMANDS="pytest" \
GITHUB_STEP_SUMMARY="$TMP/summary.md" GITHUB_OUTPUT="$TMP/out.txt" RUNNER_TEMP="$TMP" \
GITHUB_EVENT_PATH="" GITHUB_BASE_REF="" "$ENTRY" >/dev/null 2>&1
if ! grep -q 'Pre-filled evidence template' "$TMP/summary.md"; then
  pass=$((pass+1))
else
  failc=$((failc+1)); echo "FAIL: no template on confirmed claim"
fi

echo "refute-action matrix: $pass passed, $failc failed"
exit "$((failc > 0 ? 1 : 0))"
