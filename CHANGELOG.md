# Changelog

All notable changes to `refute-action` are documented here. Format loosely
follows [Keep a Changelog](https://keepachangelog.com/); versions follow
[SemVer](https://semver.org/). Tag `v1` tracks the latest `v0.x`/`v1.x` release.

## [0.1.0] — 2026-07-10

Initial public release. The CI half of the claim-evidence discipline —
Casper's sibling.

### Added
- Composite GitHub Action (`action.yml`) — bash + python3 only, zero installs.
- Claim scanning across PR title, body, and every commit message.
- Evidence recognition: `Evidence: <cmd> -> <result>` lines and test-file diffs.
- `verdict` output: `CONFIRMED` | `UNVERIFIED` | `NO-CLAIMS`.
- Inputs: `claim-words`, `test-pattern`, `scan-commits`, `scan-reviews`, `ledger`.
- Helpful mode (always on): pre-filled `Evidence:` template built from the
  detected CI command and the PR's changed source files.
- CI-command detection from `.github/workflows/*.yml`, `Makefile`, or the
  `REFUTE_CI_COMMANDS` override.
- `scan-reviews`: annotation-only note on `LGTM`/`looks good` approvals over
  unverified claims (never changes pass/fail).
- Commit-less `refute-ledger` artifact of verdict-grammar lines (`ledger: true`).
- 19-case bash test matrix (`test/run-tests.sh`) and self-CI workflow.
- MIT license, issue templates, ready-to-copy `examples/refute.yml`.

[0.1.0]: https://github.com/ronniepinnell/refute-action/releases/tag/v0.1.0
