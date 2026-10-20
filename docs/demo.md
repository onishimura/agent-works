# Demo: one issue from `agent:ready` to a proposed PR

This demo uses the public repo [`onishimura/agent-works-demo`](https://github.com/onishimura/agent-works-demo), a small Python package. The steps follow the README "Quick start". The date is 2026-10-09.

> **Name note:** this demo ran under the old project name, `trust-factory`, and the demo repo was then named `trust-factory-demo`. The clone step and the status names below use the old project name. The workflow now posts `agent-works/checks` and `agent-works/verifier`.

## Setup time

The steps ran back to back, so the times below do not include the time that a person needs to read and type.

| Step | Time |
|---|---|
| Clone trust-factory | 1 s |
| `scripts/setup.sh`: labels, config, ignored ledger, skill link | 5 s |
| Edit the config (the verify command and the test globs), commit, push | 13 s |
| Write the issue, add `agent:ready` | 30 s |
| `scripts/factory.sh run`: from `agent:ready` to a proposed PR | 63 s |
| `trust-suite/run.sh`, in parallel: the scorecard (5/5 caught, 0/3 false fails, $0.41) | 97 s |
| **Total, to a proposed PR and the scorecard** | **2 min 36 s** |

## The issue

[Issue #1: Show days in format_duration](https://github.com/onishimura/agent-works-demo/issues/1)

```markdown
## Goal
Long durations are hard to read in hours. Show days.

## Acceptance criteria
- [ ] `format_duration(90000)` returns "1d 1h".
- [ ] `format_duration(86400)` returns "1d".
- [ ] `format_duration(0)` still returns "0s".

## Out of scope
- `parse_duration`.
```

The third criterion is a trap. In the trust suite, the "silent regression" case breaks exactly this behavior.

## What happened

1. **Labels:** `agent:ready` → `agent:working` → `agent:checking` → `agent:proposed`.
2. **Build:** in its own worktree, the builder added three tests and ran them first: two failed as expected ("25h" instead of "1d 1h", "24h" instead of "1d"), and the zero test passed. Then it added the unit `d` and kept the zero case. `build.sh` pushed `agent/1` and opened [PR #2](https://github.com/onishimura/agent-works-demo/pull/2).
3. **Fixed checks:** fail-first `pass`, verify `pass`, protected paths `pass`. `check.sh` posted `trust-factory/checks: success`.
4. **Verifier:** `pass`, with a test as evidence for each criterion. `factory.sh` posted `trust-factory/verifier: success` and this evidence comment on the PR:

   | Criterion | Met | Evidence |
   |---|---|---|
   | `format_duration(90000)` returns "1d 1h". | true | test: `test_duration.FormatDurationTest.test_days_and_hours` |
   | `format_duration(86400)` returns "1d". | true | test: `test_duration.FormatDurationTest.test_exact_day` |
   | `format_duration(0)` still returns "0s". | true | test: `test_duration.FormatDurationTest.test_zero` |

5. **Result:** the PR left draft, and GitHub shows it as ready to merge (`CLEAN`). In `propose` mode, a person merges it.

The ledger line for the run:

```json
{"issue": 1, "started": "2026-10-09T13:14:45Z", "finished": "2026-10-09T13:15:40Z", "attempts": 1, "status": "proposed", "checks": ["proposed"], "verdicts": ["pass"], "pr": 2, "tokens": 119688, "cost_usd": 0.19}
```

**A failure that the demo found.** The first run of this issue gave the same code, but its PR body had the characters `\n` instead of line breaks. `build.sh` now changes such escapes into line breaks, and `agents/builder.md` asks for real line breaks. The run above is the second run, after that fix.

## Branch protection

On 2026-10-09, the demo repo required the statuses `trust-factory/checks` and `trust-factory/verifier` and an up-to-date branch on `main`. A test PR (#3, closed) showed the rule. The demo repo now requires `agent-works/checks` and `agent-works/verifier`, the names that the workflow posts today. The table below uses the old names:

| Statuses on the PR's commit | GitHub merge state |
|---|---|
| None | `BLOCKED` |
| `trust-factory/checks` success, `trust-factory/verifier` failure | `BLOCKED` |
| Both success | `CLEAN` |
