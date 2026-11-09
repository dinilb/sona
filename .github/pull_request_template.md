**What changed and why**


**How you checked it**

<!-- `make test` (and `cd ios && make test` for the iPhone app), plus anything you ran by hand with SONA_HOME
pointing at a test folder. -->

**Numbers** (only if this touches latency, accuracy or weight)

<!-- Before and after: sona-live-bench for latency, scripts/score.py for accuracy, idle CPU and memory as in
CONTRIBUTING.md. -->

**Checklist**

- [ ] Small and focused, with tests for behaviour changes
- [ ] No new dependencies, network calls, accounts or analytics
- [ ] No transcript text or note titles in logs
- [ ] No audio of real people (test clips are made with `say`)
- [ ] README or other docs updated if behaviour changed
- [ ] Commit messages in plain English, with no tool attribution lines (see CONTRIBUTING.md)
