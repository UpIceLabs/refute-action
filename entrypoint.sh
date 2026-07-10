#!/usr/bin/env bash
# entrypoint.sh — /refute GitHub Action core.
# Scans the PR body + commit messages for completion claims (fixed/done/works/…)
# and fails unless evidence is attached: an "Evidence: <command + result>" line
# in the claiming text, or a test-file diff in the PR.
#
# Dependency-free: bash + python3 + git (same contract as the local
# hooks/judgment/claim-evidence.sh hook this ports to CI).
#
# Test/override env (used by test/run-tests.sh; ignored when unset):
#   REFUTE_PR_BODY        PR title+body text
#   REFUTE_COMMIT_MSGS    commit messages separated by lines of -----8<-----
#   REFUTE_CHANGED_FILES  newline-separated changed file paths
#   REFUTE_REVIEW_BODIES  JSON array of {state, body} PR reviews (bypasses gh)
set -uo pipefail

: "${GITHUB_STEP_SUMMARY:=/dev/null}"
: "${GITHUB_OUTPUT:=/dev/null}"
: "${RUNNER_TEMP:=$(mktemp -d)}"
: "${REFUTE_CLAIM_WORDS:=}"
: "${REFUTE_TEST_PATTERN:=}"
: "${REFUTE_SCAN_COMMITS:=true}"
: "${REFUTE_SCAN_REVIEWS:=false}"
: "${REFUTE_LEDGER:=false}"

SEP='-----8<-----'
PR_BODY="${REFUTE_PR_BODY-}"
COMMITS="${REFUTE_COMMIT_MSGS-}"
CHANGED="${REFUTE_CHANGED_FILES-}"

# ---- gather from the GitHub event when not overridden ----------------------
if [ -z "$PR_BODY" ] && [ -n "${GITHUB_EVENT_PATH-}" ] && [ -f "${GITHUB_EVENT_PATH-}" ]; then
  PR_BODY="$(python3 -c '
import json, os
e = json.load(open(os.environ["GITHUB_EVENT_PATH"]))
pr = e.get("pull_request") or {}
print(((pr.get("title") or "") + "\n" + (pr.get("body") or "")).strip())
')"
fi

BASE_REF="${GITHUB_BASE_REF-}"
if [ -n "$BASE_REF" ] && git rev-parse --git-dir >/dev/null 2>&1; then
  # Needs actions/checkout with fetch-depth: 0 for full commit range.
  git fetch -q origin "$BASE_REF" 2>/dev/null || true
  MERGE_BASE="$(git merge-base "origin/$BASE_REF" HEAD 2>/dev/null || true)"
  if [ -n "$MERGE_BASE" ]; then
    [ -z "$COMMITS" ] && COMMITS="$(git log --format="%B%n$SEP" "$MERGE_BASE..HEAD" 2>/dev/null || true)"
    [ -z "$CHANGED" ] && CHANGED="$(git diff --name-only "$MERGE_BASE...HEAD" 2>/dev/null || true)"
  fi
fi

export SEP PR_BODY COMMITS CHANGED
export REFUTE_CLAIM_WORDS REFUTE_TEST_PATTERN REFUTE_SCAN_COMMITS

VERDICT_FILE="$RUNNER_TEMP/refute-verdicts.tmp"
python3 - "$VERDICT_FILE" >> "$GITHUB_STEP_SUMMARY" <<'PY'
import datetime, os, re, sys

sep = os.environ["SEP"]
docs = [("PR body", os.environ.get("PR_BODY", ""))]
if os.environ.get("REFUTE_SCAN_COMMITS", "true").lower() == "true":
    for i, msg in enumerate(os.environ.get("COMMITS", "").split(sep)):
        if msg.strip():
            first = msg.strip().splitlines()[0][:60]
            docs.append((f"commit “{first}”", msg))

words = [w.strip() for w in os.environ.get("REFUTE_CLAIM_WORDS", "").split(",") if w.strip()] or [
    "fixed", "fixes", "fix", "done", "works", "working", "complete",
    "completed", "resolved", "resolves"]
claim_re = re.compile(r"\b(" + "|".join(map(re.escape, words)) + r")\b", re.I)
evidence_re = re.compile(r"\bEvidence:\s*\S+", re.I)
test_re = re.compile(os.environ.get("REFUTE_TEST_PATTERN")
                     or r"(^|/)(tests?|__tests__|spec)/|\.(test|spec)\.|_test\.")

changed = [f for f in os.environ.get("CHANGED", "").splitlines() if f.strip()]
test_diff = [f for f in changed if test_re.search(f)]

# ---- helpful mode: build a pre-filled evidence template from the diff -------
# When a claim lacks evidence we don't just scold — we hand the author a
# ready-to-run Evidence: line assembled from what the PR actually touched:
# the test/CI commands we can detect, and the source files that changed.
def _detect_ci_commands():
    cmds = []
    # 1. Explicit override (also how the test matrix injects commands).
    for c in re.split(r"[\n,]", os.environ.get("REFUTE_CI_COMMANDS", "")):
        c = c.strip()
        if c:
            cmds.append((c, "configured"))
    # 2. Real detection from common CI/build config on disk (best-effort).
    import glob
    for wf in sorted(glob.glob(".github/workflows/*.yml")
                     + glob.glob(".github/workflows/*.yaml")):
        try:
            for ln in open(wf, encoding="utf-8", errors="replace"):
                m = re.search(r"\b(pytest|npm (?:run )?test|make test|"
                              r"go test|cargo test|tox|jest|vitest|"
                              r"python -m pytest)\b[^\n|]*", ln)
                if m:
                    cmds.append((m.group(0).strip(), os.path.basename(wf)))
        except OSError:
            pass
    if os.path.isfile("Makefile"):
        try:
            for ln in open("Makefile", encoding="utf-8", errors="replace"):
                if re.match(r"^(test|check)\s*:", ln):
                    cmds.append(("make " + ln.split(":", 1)[0].strip(),
                                 "Makefile"))
        except OSError:
            pass
    # De-dup, keep first source seen, cap the list.
    seen, out = set(), []
    for cmd, src in cmds:
        if cmd not in seen:
            seen.add(cmd)
            out.append((cmd, src))
    return out[:6]

def _template_block():
    ci = _detect_ci_commands()
    src_files = [f for f in changed if not test_re.search(f)][:6]
    lines = ["### Pre-filled evidence template (helpful mode)\n",
             "Copy this, run the command, paste the real output — then this "
             "check goes green:\n", "```"]
    first_cmd = ci[0][0] if ci else "<your test command>"
    lines.append(f"Evidence: {first_cmd} -> <paste observed result here>")
    lines.append("```\n")
    if ci:
        lines.append("Commands detected in this repo's CI/build config:\n")
        for cmd, src in ci:
            lines.append(f"- `{cmd}`  _(from {src})_")
        lines.append("")
    if src_files:
        lines.append("Source files this PR changed that likely need a test "
                     "asserting the fix:\n")
        for f in src_files:
            lines.append(f"- `{f}`")
        lines.append("")
    return "\n".join(lines)

unverified, confirmed, claims_seen = [], [], 0
for name, text in docs:
    m = claim_re.search(text)
    if not m:
        continue
    claims_seen += 1
    if evidence_re.search(text):
        confirmed.append((name, m.group(0), "Evidence: line present"))
    elif test_diff:
        confirmed.append((name, m.group(0), f"test diff: {test_diff[0]}"))
    else:
        unverified.append((name, m.group(0)))

today = datetime.date.today().isoformat()
verdict = "NO-CLAIMS" if claims_seen == 0 else ("UNVERIFIED" if unverified else "CONFIRMED")

lines = []
for name, word in unverified:
    lines.append(f'{today} | REFUTE | UNVERIFIED "{word}" claim in {name} | missing: evidence | by: refute-action')
for name, word, ev in confirmed:
    lines.append(f'{today} | REFUTE | CONFIRMED "{word}" claim in {name} | evidence: {ev} | by: refute-action')
with open(sys.argv[1], "w") as f:
    f.write(f"VERDICT={verdict}\n")
    for ln in lines:
        f.write(ln + "\n")

# ---- GITHUB_STEP_SUMMARY (stdout) ----
print(f"## /refute — claim-evidence check: **{verdict}**\n")
if verdict == "NO-CLAIMS":
    print("No completion claims found in the PR body or commit messages. Nothing to verify.")
elif verdict == "CONFIRMED":
    print("Every completion claim carries evidence:\n")
    for name, word, ev in confirmed:
        print(f'- `{word}` in {name} — {ev}')
else:
    print("These completion claims carry **no evidence**:\n")
    for name, word in unverified:
        print(f'- `{word}` claim in {name}')
    print()
    print(_template_block())
    print("""
### How to fix (pick one)

1. **Attach evidence** — add a line to the PR body (or amend the commit message):

   ```
   Evidence: <command you ran> -> <observed result>
   e.g. Evidence: pytest tests/test_calc.py -> 12 passed in 0.4s
   ```

2. **Ship the proof** — include a test-file diff in this PR
   (paths matching `tests?/`, `__tests__/`, `spec/`, `*.test.*`, `*_test.*`).

3. **Drop the claim** — if it isn't verified yet, don't say fixed/done/works.

### Verdict grammar (goes to your ledger)

```
YYYY-MM-DD | REFUTE | UNVERIFIED "<claim>" | missing: evidence | by: refute-action
YYYY-MM-DD | REFUTE | CONFIRMED "<claim>" | evidence: <cmd -> result> | by: refute-action
```

A claim is a liability until refutation was attempted and failed.""")
print()
print("Ledger lines emitted:\n")
print("```")
for ln in lines or ["(none)"]:
    print(ln)
print("```")
PY

VERDICT="$(head -n1 "$VERDICT_FILE" | cut -d= -f2)"
echo "verdict=$VERDICT" >> "$GITHUB_OUTPUT"

# ---- review-approval scan (annotate-only, NEVER fails the check) ------------
# When scan-reviews=true and the claims above lack evidence, look at PR review
# bodies for premature "LGTM"/"looks good" approvals and add a gentle note to
# the job summary. Fetch order: REFUTE_REVIEW_BODIES override, else gh api
# (requires GITHUB_TOKEN + gh + PR number in the event) — graceful skip if any
# piece is missing.
if [ "$(echo "$REFUTE_SCAN_REVIEWS" | tr '[:upper:]' '[:lower:]')" = "true" ] \
   && [ "$VERDICT" = "UNVERIFIED" ]; then
  REVIEWS_JSON="${REFUTE_REVIEW_BODIES-}"
  if [ -z "$REVIEWS_JSON" ]; then
    PR_NUM=""
    if [ -n "${GITHUB_EVENT_PATH-}" ] && [ -f "${GITHUB_EVENT_PATH-}" ]; then
      PR_NUM="$(python3 -c '
import json, os
e = json.load(open(os.environ["GITHUB_EVENT_PATH"]))
print((e.get("pull_request") or {}).get("number") or "")')"
    fi
    if [ -n "$PR_NUM" ] && [ -n "${GITHUB_TOKEN-}" ] && [ -n "${GITHUB_REPOSITORY-}" ] \
       && command -v gh >/dev/null 2>&1; then
      REVIEWS_JSON="$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUM/reviews" \
        --jq '[.[] | {state: .state, body: (.body // "")}]' 2>/dev/null || true)"
    fi
  fi
  if [ -n "$REVIEWS_JSON" ]; then
    REVIEWS_JSON="$REVIEWS_JSON" python3 - >> "$GITHUB_STEP_SUMMARY" <<'PY'
import json, os, re, sys

try:
    reviews = json.loads(os.environ["REVIEWS_JSON"])
except ValueError:
    sys.exit(0)  # malformed fetch: annotate nothing, never fail
lgtm_re = re.compile(r"\blgtm\b|looks\s+good|:shipit:|ship\s+it", re.I)
approvals = [r for r in reviews if isinstance(r, dict)
             and (r.get("state", "").upper() == "APPROVED"
                  or lgtm_re.search(r.get("body") or ""))]
if approvals:
    print("\n### Note: approvals on unverified claims (informational only)\n")
    print(f"{len(approvals)} review(s) approve or say LGTM/looks good, but the "
          "completion claims above still carry **no evidence**. Consider "
          "asking the author for an `Evidence:` line or a test diff before "
          "merging. This note never fails the check.\n")
    for r in approvals[:5]:
        body = (r.get("body") or "").strip().splitlines()
        first = body[0][:80] if body else "(no comment)"
        print(f'- {r.get("state", "?")}: "{first}"')
PY
  else
    echo "refute: scan-reviews requested but reviews unavailable (no token/gh/PR) — skipped." >&2
  fi
fi

# ---- commit-less ledger fragment (uploaded as artifact by action.yml) ------
if [ "$REFUTE_LEDGER" = "true" ]; then
  mkdir -p "$RUNNER_TEMP/refute-ledger"
  tail -n +2 "$VERDICT_FILE" >> "$RUNNER_TEMP/refute-ledger/verdicts.log"
  echo "refute: ledger fragment at $RUNNER_TEMP/refute-ledger/verdicts.log (merge into .claude/verdicts.log)"
fi

if [ "$VERDICT" = "UNVERIFIED" ]; then
  echo "refute: UNVERIFIED completion claim(s) — see the job summary for the exact fix." >&2
  exit 1
fi
echo "refute: $VERDICT"
exit 0
