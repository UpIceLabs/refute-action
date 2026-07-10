---
name: Bug report
about: refute blocked (or passed) a PR when it shouldn't have
title: "[bug] "
labels: bug
---

**What happened**
<!-- e.g. refute failed a PR whose body had a valid Evidence: line -->

**The PR text refute scanned**
<!-- paste the PR body / commit message / relevant claim -->

**Expected verdict**
<!-- CONFIRMED / UNVERIFIED / NO-CLAIMS -->

**Actual verdict + job summary**
<!-- paste the job summary and the `verdict` output -->

**Your workflow step**
```yaml
# the `uses: ronniepinnell/refute-action@...` block + inputs
```

**Environment**
- Action version / tag:
- Runner: ubuntu-latest / other:
