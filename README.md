# refute — PR-level claim-evidence enforcement

> **Your AI opened a PR that says "done." This makes it prove it, on the PR.**

`refute` scans the PR title, body, and every commit message for **completion
claims** — `fixed`, `done`, `works`, `complete`, `resolved`, … — and fails the
check unless evidence is attached:

1. an `Evidence: <command you ran> -> <observed result>` line in the claiming
   text, **or**
2. a test-file diff in the PR (`tests/`, `__tests__/`, `spec/`, `*.test.*`,
   `*_test.*`).

It is the CI port of the local `claim-evidence.sh` PreToolUse hook: local hooks
guard `git commit`; this Action guards the real trust boundary — the merge.
Zero dependencies beyond bash + python3 (present on every GitHub runner). No
node, no npm, nothing to install.

<!-- SCREENSHOT SLOT: replace with the real dogfood GIF/PNG of refute failing a
     Casper PR (job summary + pre-filled Evidence template). Record by running
     this Action on an actual PR, then:
     ![refute failing a PR with a pre-filled Evidence template](docs/refute-demo.png) -->

## Usage

Drop this into `.github/workflows/refute.yml` of any repo:

```yaml
# .github/workflows/refute.yml
name: refute
on:
  pull_request:
    types: [opened, edited, synchronize, reopened]

permissions:
  contents: read

jobs:
  refute:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0        # full history so all PR commits are scanned
      - uses: ronniepinnell/refute-action@v1
        with:
          ledger: true          # optional: upload verdict lines as an artifact
```

A ready-to-copy consumer workflow lives in
[`examples/refute.yml`](examples/refute.yml).

## Inputs

| input | default | what it does |
|---|---|---|
| `claim-words` | `fixed,fixes,fix,done,works,working,complete,completed,resolved,resolves` | comma-separated override of the completion-claim word list |
| `test-pattern` | `(^\|/)(tests?\|__tests__\|spec)/\|\.(test\|spec)\.\|_test\.` | python regex; changed files that match count as evidence |
| `scan-commits` | `true` | also scan every commit message in the PR range, not just the PR body |
| `scan-reviews` | `false` | fetch PR review bodies and, on an unverified claim, add a job-summary note about `LGTM`/`looks good` approvals. **Annotation only — never changes pass/fail.** |
| `ledger` | `false` | upload REFUTE verdict lines as a commit-less `refute-ledger` artifact |

**Helpful mode is always on.** Whenever a claim lacks evidence, the failure
isn't just "no" — it builds a copy-paste `Evidence:` template from what the diff
actually shows (see below). There is no toggle to disable teaching.

## Outputs

| output | values |
|---|---|
| `verdict` | `CONFIRMED` \| `UNVERIFIED` \| `NO-CLAIMS` |

## The verdict grammar

Every decision `refute` makes is expressible as one line in a fixed grammar —
the same grammar Casper's local hooks and `/verdict` skill emit, so CI verdicts
and local verdicts merge into one ledger:

```
<date> | REFUTE | <VERDICT> <what was claimed> | <evidence-or-gap> | by: refute-action
```

- **`CONFIRMED`** — a claim was made *and* backed (Evidence line or test diff). Check passes.
- **`UNVERIFIED`** — a claim was made with no backing. Check **fails**.
- **`NO-CLAIMS`** — nothing claimed completion; nothing to prove. Check passes.

Example line on a block:

```
2026-07-10 | REFUTE | UNVERIFIED "done" claim in PR body | missing: evidence | by: refute-action
```

## What a failure looks like

The job summary tells the author exactly how to fix it — attach an `Evidence:`
line, ship the test diff, or drop the claim — and emits the verdict line above.

### Helpful mode (teaches, doesn't scold)

When a claim lacks evidence, the summary builds a **pre-filled `Evidence:`
template from what the diff actually shows** so the author can copy, run, paste:

- the test/CI command it detects — from a `REFUTE_CI_COMMANDS` override, from
  your `.github/workflows/*.yml` (`pytest`/`npm test`/`go test`/`make test`/…),
  or a `test:`/`check:` target in your `Makefile`;
- the **source files this PR changed** (non-test) listed as "likely need a
  test," pointing at exactly what's unproven.

So the failure reads like a starting point, not a rejection:

```
Evidence: pytest tests/ -q -> <paste observed result here>
```

## The ledger (`ledger: true`)

Verdict lines are uploaded as a `refute-ledger` artifact instead of being
committed (commit-less by design — CI must not push to your branch). Merge them
into your repo's append-only `.claude/verdicts.log` whenever you like:

```bash
gh run download <run-id> -n refute-ledger
cat verdicts.log >> .claude/verdicts.log
```

**Correction history is the asset.** A refuted claim isn't friction — it's a
recorded moment where the work had to prove itself. The ledger keeps that
history so "done" stops being a word and starts being a track record.

## Testing

```bash
./test/run-tests.sh   # block/pass matrix, plain bash, no framework
```

The Action's own repo runs this matrix on every push and PR (see
[`.github/workflows/ci.yml`](.github/workflows/ci.yml)).

## Casper — the local-hooks companion

`refute` is the CI half. [**Casper**](https://github.com/ronniepinnell/casper)
is the local half: the same claim-evidence discipline as a `git commit`-time
hook, plus a toolkit of judgment skills (`/verdict`, `/gate`, `/premortem`,
`/calibrate`, …). Same thesis, two trust boundaries:

- **Casper** stops an unproven "done" before it becomes a commit.
- **refute** stops one before it becomes a merge.

Use either alone; use both to close the loop from keystroke to `main`.

## License

MIT © Ronnie Pinnell
