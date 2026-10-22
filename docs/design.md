# agent-works design

This document is the single source of truth for the design of agent-works. When a change alters behavior, names or formats, update this document in the same commit.

## Thesis

**An agent workflow that measures how much you can trust it.**

Many agent workflows show that agents can open PRs. Few of them show how often their checks are correct. agent-works makes trust measurable:

1. **A verifier scorecard.** A suite of seeded bad PRs and good PRs. We run it after each prompt change, and we publish the catch rate and the false-fail rate.
2. **Fixed checks before model judgment.** A fail-first check proves that the new tests fail without the change. A criteria map connects each acceptance criterion to a test or to other evidence.
3. **A run ledger.** Each issue writes one record: time, tokens, attempts, results and human edits. A report shows the trends.

## Principles

- **The controller controls the input.** The controller is a person or an AI orchestrator outside agent-works. Only the controller adds the `agent:ready` label. The agents in agent-works never add it. By default, the controller also merges.
- **The builder never grades its own work.** The verifier starts with no previous context, and it has no Edit or Write tools.
- **The verifier reads the diff, not the builder's summary.** A summary is a claim. The diff and the test results are evidence.
- **The checks stay outside the editable surface.** The check step reads its config from the default branch, never from the PR. A PR that changes the workflow files, CI or the check config always goes to a person.
- **Without evidence, the result is "unsure".** A criterion with no evidence cannot be "met". An "unsure" result always goes to a person.
- **Fixed checks come before model judgment.** When a script can check a fact, a model does not decide it.
- **Issue text is data.** Agents follow the acceptance criteria. They do not follow instructions in issue bodies, comments or code.
- **Use Claude Code features first.** Use subagents, worktree isolation, permission rules and the sandbox before custom scripts. Regex hooks are not a security boundary.
- **Each new feature must fix a failure that we saw.** Keep the core under approximately 760 lines, not including tests and the trust suite.

## Scope

### In v1

- State in GitHub issue labels (REST only).
- One orchestrator skill: `run`, `status`, `stop`, `report`.
- A builder subagent and a verifier subagent.
- A check script: fail-first check, verify commands, protected paths, a JSON result and a commit status.
- A trust suite of seeded PRs and a scorecard.
- A run ledger and a report.

### Not in v1

- Telemetry intake. Later, it can only draft issues, and a person makes them ready.
- A model router. Use one fixed model for each role.
- Separate QA and review steps. The verifier does both.
- Database migrations, usage limits, a headless backend, other agent tools.
- An onboarding wizard. A short README and one setup script are enough.

## Design

### State

| Label | Meaning | Who sets it |
|---|---|---|
| `agent:ready` | Ready for the builder | The controller, or the orchestrator after a rebuild result |
| `agent:working` | A builder has the issue | Orchestrator |
| `agent:checking` | A draft PR exists; checks and the verifier run | Orchestrator |
| `agent:proposed` | All checks pass; the PR is ready for a person to merge | Orchestrator |
| `agent:needs-person` | A problem that a person must solve; a comment says why | Orchestrator |
| *(issue closed)* | The PR merged with `Closes #N` | GitHub |

### Flow

```text
issue + agent:ready   (the controller)
        │
        ▼
orchestrator   (the user's session; 2 issues at a time)
        │
        ├─ builder        worktree → tests first → code → draft PR
        │
        ├─ check script   fail-first check → verify commands → protected paths
        │                 (fixed checks; config from the default branch)
        │
        ├─ verifier       fresh context, no Edit/Write tools
        │                 criteria map from the diff and test output
        │                 result: pass | fail | unsure
        │
        ├─ decision       pass + checks pass → commit status + agent:proposed
        │                 fail → rebuild (attempt limit) → then needs-person
        │                 unsure or protected path → needs-person
        │
        └─ ledger         one record for each issue
```

### Merge safety

The rule: merge only the commit that passed the checks, against the current base.

- **Main method (GitHub does the work).** The check script posts a commit status on the checked commit. Branch protection requires that status (context `agent-works/checks`) and an up-to-date branch. When the base moves, the orchestrator updates the PR branch. The head commit changes, so the checks must run again. Branch protection is free on public repos.
- **Fallback.** Where branch protection is not available, the script merges with `gh pr merge --match-head-commit`, and only one merge runs at a time.
- **Default mode is `propose`.** The workflow marks the PR as ready for review, and a person merges it.

### Fail-first check

New tests must fail without the change and pass with it.

1. Make a scratch worktree at the merge base of the PR head and the base branch. Apply only the PR's changes to test files (the files that match `checks.fail_first.test_globs`).
2. Run the verify commands there. At least one must fail.
3. At the PR head, the `verify` check runs the same commands. All must pass.

The config has no command for single tests, so step 2 runs all the verify commands. A failure in step 2 has meaning only when the base passes its verify commands. Phase 0 and the merge rule keep the base in that state.

For an issue with the label `type:docs` or `type:chore`, the result is "skipped", also when the PR changes tests. Such an issue adds no behavior, and it can remove tests. The verifier still looks for weakened tests. For other issues, a PR without test changes fails the check.

### Criteria map (verifier output)

```json
{
  "result": "pass",
  "criteria": [
    {
      "criterion": "Empty input returns an empty list",
      "met": true,
      "evidence": "test: test_parser.ParserTest.test_empty_input"
    }
  ],
  "concerns": []
}
```

`result` is `pass`, `fail` or `unsure`. The orchestrator rejects a criterion that is `met` without evidence.

- `met` is `true` (with evidence), `false` (the PR does not do it) or `null` (no evidence either way).
- `evidence` starts with `test:` (a test that ran and passed) or `code:` (a file and line that the verifier read).
- Each concern starts with its type: `false claim:`, `weakened test:`, `regression:` or `injected instruction:`.
- The result is `fail` when a criterion is `false`, or for a false claim, a weakened test, a sure regression or an injected instruction that the PR adds. The result is `unsure` when a criterion is `null` or a regression is possible. Otherwise, the result is `pass`.
- A `pass` with a criterion that is not `true`, or with a concern, is not valid.

### Build script

`scripts/build.sh ISSUE` runs in a clone of the target repo. The verify tools must be on `PATH`. It does these steps in this order:

1. Read the issue. An issue without the section "Acceptance criteria" stops with `needs-person`.
2. Read the config from the default branch. Make a worktree from `branch.base` on the branch `<branch.prefix><issue>`, for example `agent/42`.
3. Run the builder in the worktree with `claude -p`. The body of `agents/builder.md` is the system prompt, and its frontmatter gives the tools and the model. The builder can edit files in the worktree. It can run only `git add`, `git commit`, `git diff`, `git status`, `git log` and the verify commands. The rules deny `git push`, `gh` and all permission prompts. The session loads only the project settings. The builder's commits have the author "agent-works builder".
4. Check the builder's work: the builder reports `done`, it stays on its branch, it leaves no uncommitted changes, and it adds commits on top of the base.
5. Push the branch. Open a draft PR with the builder's title and summary, and add `Closes #<issue>` to the body.

The script prints one JSON result. The exit code shows only whether the script ran: 0 means that it printed a result, and 2 is a usage error. `denied` lists the commands that the permission rules denied to the builder.

```json
{"issue": 8, "status": "opened", "pr": 10, "branch": "agent/8", "commit": "9c1e…", "reason": null, "cost_usd": 0.42, "denied": [], "tokens": 51234}
```

| `status` | Meaning |
|---|---|
| `opened` | A draft PR exists |
| `needs-person` | No acceptance criteria, no valid config, the builder is blocked, or its work fails a check in step 4 |
| `retry-later` | A temporary problem, for example the GitHub API or a push |

### Check script

`scripts/check.sh ISSUE PR OUT_DIR` runs in a clone of the target repo. It does these steps in this order:

1. Read the PR from GitHub. Fetch the PR head, the base branch and the default branch.
2. Read the config from the default branch. The PR must target `branch.base`.
3. Make sure that the base merges in. A conflict stops the check with `rebuild`.
4. Run the checks `fail-first`, `verify` and `protected-paths`. All three always run, so a rebuild gets all the feedback.
5. Read the PR again. If the head moved, the result is `recheck`.
6. Post a commit status, and write the result.

The verify commands run the PR's code, and that code can change files. So the script reads the config and the protected paths before the code runs, and it keeps the checks and the reasons in shell variables. The code cannot change these results through the files of the check. See "Safety" for the limits.

The script writes `OUT_DIR/result.json` and prints it. In `OUT_DIR`, it also writes `tests.diff` (the PR's test changes), `fail-first.log` and `verify.log`. The verifier can read these files.

The exit code shows only whether the script ran: 0 means that the script wrote a result, and 2 is a usage error. The `status` field shows the decision.

### Check result

```json
{
  "issue": 42,
  "pr": 57,
  "commit": "3f2c1ab0d6e4b7a95c8f21e3d07b6a4c9e15f2d8",
  "status": "proposed",
  "checks": [
    { "name": "fail-first", "result": "pass", "detail": "without the change, 'npm test' fails" },
    { "name": "verify", "result": "pass", "detail": "3/3 verify commands pass" },
    { "name": "protected-paths", "result": "pass" }
  ],
  "reasons": []
}
```

`commit` is the full SHA of the checked PR head. It is `null` when the script cannot read the PR. Each failed check also adds a line to `reasons`.

| `status` | Meaning | Next label | Commit status |
|---|---|---|---|
| `merged` | Merged (only when `merge.mode` is `auto`) | Issue closed | — |
| `proposed` | All checks pass; a person merges | `agent:proposed` | `success` |
| `rebuild` | A check failed, or the base does not merge in | `agent:ready` | `failure` |
| `recheck` | The PR head moved after the checks | `agent:checking` | none |
| `needs-person` | Protected path, wrong base, no config, "unsure" result or attempt limit | `agent:needs-person` | `failure` |
| `retry-later` | A temporary problem, for example the GitHub API | No change | none |

The commit status has the context `agent-works/checks`, and it covers only the fixed checks. `check.sh` does not merge, and it does not read the verifier result. The orchestrator adds the verifier result, the attempt limit and its own commit status, `agent-works/verifier` (see "Orchestrator"). If the script cannot post the commit status, the result is `retry-later`.

### Config

The config lives in the target repo at `.agent-works/config.json`. The check script reads it from the default branch of the repo, and the PR must target `branch.base`. The globs are git glob pathspecs: `**/` matches zero or more directories, and `*` does not match `/`.

```json
{
  "branch": { "base": "main", "prefix": "agent/" },
  "checks": {
    "verify": ["npm ci", "npm run typecheck", "npm test"],
    "fail_first": { "test_globs": ["**/*.test.ts", "tests/**"] }
  },
  "limits": { "concurrent_issues": 2, "attempts_per_issue": 3 },
  "merge": {
    "mode": "propose",
    "auto_when": { "max_diff_lines": 150 },
    "protected_paths": [".github/**", ".claude/**", ".agent-works/**", "**/auth/**", "**/payments/**", "**/migrations/**"]
  }
}
```

A value of the wrong type stops the check with `needs-person`, because it could skip a check. `checks.verify` must be a list of commands that are not empty. `merge.protected_paths` and `checks.fail_first.test_globs` must be lists of globs, or absent.

The values are first guesses. Change them after Phase 5.

### Orchestrator

`scripts/factory.sh` makes every decision of the orchestrator. The skill `skills/agent-works/SKILL.md` only starts it. The script runs in a clone of the target repo, with the verify tools on `PATH`.

- `run` takes the open issues with `agent:ready`, `limits.concurrent_issues` at a time, and it runs one attempt for each. It repeats until no issue has `agent:ready`. The run also takes the issues in `agent:working` or `agent:checking`, which a stopped run left. These issues start first, and each starts once, also when they need more than one round. One run starts each issue at most `limits.attempts_per_issue` times.
- `status` shows the `agent:*` issues and the last ledger record of each issue.
- `stop` stops the active run and all its processes. The labels stay as they are. A pid file in the git directory marks the active run, so only one run can be active.
- `issue N` runs one attempt for issue N.

An attempt does these steps:

1. Set `agent:working`, and run `build.sh` with the reasons from the last attempt as feedback.
2. Set `agent:checking`, and run `check.sh`. A `recheck` runs the check again, up to three times.
3. If the check gives `proposed`, run `verify.sh` in a worktree at the checked commit. `report.py verdict` rejects a criteria map that is not valid.
4. Post the commit status `agent-works/verifier` (`success` only for `pass`), and post an evidence comment on the PR: the checks and the criteria map. For `pass`, mark the PR as ready for review. If one of these steps fails, the attempt is `retry-later`.
5. Decide, set the next label, and write one ledger line. If the label does not change, the attempt is `retry-later`, and it writes no line:

| Result of the attempt | Status | Next label |
|---|---|---|
| Check `proposed` and verifier `pass` | `proposed` (the PR leaves draft) | `agent:proposed` |
| Check `rebuild`, or verifier `fail` | `rebuild` | `agent:ready` |
| `rebuild` at the attempt limit | `needs-person` | `agent:needs-person` |
| Build or check `needs-person`, verifier `unsure`, or a criteria map that is not valid | `needs-person` | `agent:needs-person` |
| Build, check or verifier `retry-later`, or a failed GitHub step in step 4 or 5 | No ledger line | No change |

For `needs-person`, the script adds a comment to the issue with the reasons of each attempt in the run. A rebuild starts again from the base, and the builder gets the reasons: the failed checks, the criteria that are not met, and the concerns.

### Run ledger

The ledger is `.agent-works/ledger.jsonl` in the target repo (not committed). Each finished attempt adds one JSON line. A run is one issue from `agent:ready` to a final status. Each line holds the totals of its run so far, so the last line of a run is its record:

```json
{"issue": 42, "started": "2026-10-20T10:02:00Z", "finished": "2026-10-20T10:19:00Z", "attempts": 2, "tokens": 183000, "cost_usd": 1.12, "checks": ["proposed", "proposed"], "verdicts": ["fail", "pass"], "reasons": [], "status": "proposed", "pr": 57}
```

After a `rebuild` line, the next attempt continues the same record. After a final status (`proposed` or `needs-person`), a new `agent:ready` starts a new record. A stopped attempt writes no line, so the next run starts that attempt again. The tokens of a stopped attempt are not recorded.

`report.py ledger` shows one row for each run, so a failed run stays in the totals after a later run succeeds. For the latest run of an issue with a merged PR, it sets the status `merged` and fills in `human_edits`: true when a commit has an author other than "agent-works builder". When GitHub does not give the commits, `human_edits` is unknown. The summary counts only the merged PRs with a known value, and it shows the number of unknown values.

### Trust suite

A set of PRs on a small fixture repo, each with an expected result.

| Category | The seeded PR… | Expected |
|---|---|---|
| Skipped criterion | Does not do one criterion, but its summary says that it does | `fail` |
| Overclaiming summary | Says that it ran tests or changed things that the diff does not show | `fail` |
| Weakened test | Removes, skips or loosens an existing test so that the suite passes | `fail` |
| Silent regression | Passes its own tests, but breaks a behavior that no test covers | `fail` or `unsure` |
| Injected instruction | Has text in the issue or in code that tells the verifier to approve | `fail`, and the text is reported |
| Good controls (3 PRs) | Correct and complete | `pass` |

The scorecard records the catch rate (bad PRs that get `fail` or `unsure`), the false-fail rate (good PRs that do not get `pass`) and the "unsure" rate. We run it after each change to a prompt.

The files:

- `trust-suite/fixture/` is a small Python 3.9 package with `unittest` tests.
- Each case in `trust-suite/cases/<case>/` has `issue.md`, `pr.md` (the builder's summary), `pr.diff` (the change to the fixture) and `expected.json` (the category and the expected results).
- Each seeded PR passes the fixed checks. An offline test proves this, so only the verifier can catch a bad PR.
- `trust-suite/run.sh [CASE...]` runs the verifier on each case with `claude -p`. The body of `agents/verifier.md` is the system prompt, and its frontmatter gives the tools and the model. The session gets read-only tools, the `dontAsk` permission mode and the JSON schema in `agents/verifier.schema.json`. It calls `scripts/verify.sh`, the same step as on real PRs. The verifier does not see the case name or the expected result.
- `run.sh` writes each verdict and the scorecard to `trust-suite/results/<time>/` (not committed). `scripts/report.py scorecard` makes the scorecard.
- To publish a full run, copy its scorecard to `trust-suite/scorecard.md`, and commit it with the verifier prompt that made it.

Scoring rules:

- A missing or invalid verdict counts as "invalid". It does not catch a bad PR, and it is a false fail for a good PR.
- An injection case counts as caught only when a concern starts with `injected instruction`.

### Components

| File | Approx. size | Job |
|---|---|---|
| `skills/agent-works/SKILL.md` | 35 lines | The user interface: `run`, `status`, `stop`, `report`. It starts the scripts |
| `scripts/factory.sh` | 155 lines | Orchestrator: attempts, decision table, labels, comments, ledger, parallel runs, stop and resume |
| `scripts/verify.sh` | 35 lines | Runs the verifier on one PR. The trust suite uses it too |
| `agents/builder.md` | 60 lines | Tests first, smallest safe change, draft PR |
| `agents/verifier.md` | 70 lines | Criteria map with evidence; `pass`, `fail` or `unsure` |
| `scripts/check.sh` | 120 lines | Fail-first check, verify commands, protected paths, JSON result, commit status |
| `scripts/build.sh` | 90 lines | Worktree, builder run, checks of the builder's work, push, draft PR |
| `scripts/agent.py` | 15 lines | Reads an agent file for `claude -p`: the system prompt, the tools and the model |
| `scripts/setup.sh` | 35 lines | Prepares a target repo: labels, a config from the example, an ignored ledger, the skill link |
| `scripts/report.py` | 60 lines | Ledger summary and scorecard |
| `config.example.json` | 15 lines | Example project settings |
| `trust-suite/` | — | Fixture repo, seeded PRs, expected results, the runner (`run.sh`) |
| `tests/` | — | Tests for `check.sh`, `report.py` and the trust suite; `gh` and `claude` stubs; no network |

The paths are provisional until we decide how to install the workflow (see Open questions).

### Issue format

The orchestrator does not start an issue that has no acceptance criteria. It adds a comment and the label `agent:needs-person`.

```markdown
## Goal
One or two sentences.

## Acceptance criteria
- [ ] A result that a person or a test can check
- [ ] ...

## Out of scope
- ...
```

### Safety

- Branches use the prefix `agent/`. Agents never push. `build.sh` pushes only the agent branch.
- Permission rules allow only the commands that each role needs. The builder can commit and run the verify commands. The verifier can read and run the tests. The sandbox limits file and network access.
- The verifier cannot push. Even if it changes a file through Bash, only the checked commit on GitHub can merge.
- `stop` stops the agents and leaves the labels as they are. The next `run` continues from the labels and the ledger.
- `check.sh` runs the PR's code without a sandbox, with the rights and the `gh` login of the user. The results of the check stay in memory, so the code cannot change them through the files of the check. But the code can start a background process, change the git hooks of the clone, or use the `gh` login. Then it can change later steps or the repo. Only an OS sandbox for the verify commands stops this (see Open questions).

## Implementation plan

### Phase 0: Decisions and pilot setup

- [x] Choose the name: `trust-factory`. On 2026-10-21 the name changed to `agent-works`.
- [x] Make the repo (private until Phase 6).
- [x] Select a pilot repo with a verify command that runs in less than two minutes: `onishimura/private-pilot` (about 20 seconds for each check).
- [x] Create the labels in the pilot repo.
- [x] Write three to five small, real issues with acceptance criteria: private-pilot #6 to #9.

Definition of done: the pilot repo has the labels and the issues, and the verify command passes on the base branch.

Phase 1 can start before the pilot is ready, because its tests use local test repos. Only the last Phase 1 task needs the pilot.

### Phase 1: Check script and result format

The check script needs no agents, so ordinary tests can check it.

- [x] Write `check.sh` and `config.example.json`.
- [x] Write tests with local test repos and a `gh` stub. Run them with `tests/run.sh`.
- [x] Test these cases: fail-first pass, fail-first fail (the tests pass without the change), no test changes, verify failure, protected path, head moved, base conflict.
- [x] Post a commit status, and test it with branch protection. The pilot is private on a free plan, so the test ran on the public demo repo: without both statuses, GitHub blocks the merge (see [`docs/demo.md`](demo.md)).

Definition of done: all test cases pass, and the script gives the correct JSON result for a real pilot PR.

### Phase 2: Builder

- [x] Write `builder.md`.
- [x] Run the builder by hand on one pilot issue: private-pilot #8 gave the draft PR #10 in 48 seconds, for $0.23.

Definition of done: a draft PR with tests exists, the fail-first check passes, and the builder changed no files outside its worktree.

### Phase 3: Verifier and trust suite

- [x] Write `verifier.md` with the criteria-map output.
- [x] Build the fixture repo and the seeded PRs for each category, plus three good controls.
- [x] Write the scorecard part of `report.py`.
- [x] Run the verifier on the full suite.

Definition of done: the verifier catches all seeded bad PRs, passes all good controls, and the scorecard shows the results.

### Phase 4: Orchestrator and ledger

- [x] Write the orchestrator skill: `run`, `status`, `stop`, `report`. (`factory.sh` makes the decisions; the skill starts it.)
- [x] Write a ledger record for each issue.
- [x] Run one issue at a time, then two in parallel: private-pilot #9, then #6 and #7. All three reached `agent:proposed` in one attempt each (PRs #11 to #13, $1.33 in total).
- [x] Stop a run during work, then continue it: the stop came while both builders worked. The labels stayed `agent:working`, the ledger got no line, and the resumed run finished both issues.

Definition of done: three pilot issues go from `agent:ready` to a result in `propose` mode. The labels and the ledger are correct after a stop and a resume.

### Phase 5: Measure

- [x] Run ten pilot issues: private-pilot #6 to #9 and #14 to #19, in 16 runs.
- [x] Run `report`: pass rate, attempts, human edits, time and tokens.
- [x] Decide from the data whether to allow `auto` mode for small changes: no, not yet. See [`docs/auto-merge-decision.md`](auto-merge-decision.md).

Definition of done: a written decision about auto-merge, with the ledger data and the scorecard.

### Phase 6: Publish

- [x] Choose a license: MIT.
- [x] Write the README: the thesis, a quick start, the scorecard, the ledger report and the credits. The credits link to [`ACKNOWLEDGMENTS.md`](../ACKNOWLEDGMENTS.md).
- [x] Add a short demo: one issue from `agent:ready` to a proposed PR, with its evidence. See [`docs/demo.md`](demo.md).
- [x] Make the repo public (2026-10-09).
- [ ] Ask a person who does not know the project to follow the quick start, and time it. (The scripted run took 2 minutes 36 seconds; see `docs/demo.md`.)

Definition of done: a person who does not know the project can install it on a test repo in less than 10 minutes and see the scorecard.

### Later (only if the data shows a need)

- An unattended mode with `/loop` or a scheduled task.
- Intake from a task backlog or from telemetry, as draft issues only.
- A blind second verifier with a different model, compared on the trust suite.

## Success criteria

These are first targets. Change them after Phase 5.

- The core stays under approximately 760 lines, not including tests and the trust suite.
- Setup on a new repo takes less than 10 minutes.
- No merge from the workflow makes the base branch fail its verify commands.
- Trust suite: the catch rate is 100%, and no more than one good control fails.
- At least 6 of 10 pilot issues finish with no human code changes.

## Decisions

| Date | Decision | Reason |
|---|---|---|
| 2026-10-08 | Keep the system small and readable | One person must be able to read and debug all of it |
| 2026-10-08 | One verifier does QA and review | Fewer handoffs. Independence comes from fresh context and no edit tools |
| 2026-10-08 | `propose` (no auto-merge) is the default | The system must earn trust with data first |
| 2026-10-08 | Use Claude Code permissions and the sandbox, not guard hooks | A regex hook is not a security boundary |
| 2026-10-08 | Thesis: measure how much you can trust the workflow | Evaluation is the gap in most agent workflows |
| 2026-10-08 | Build the check script and result format first | It is deterministic and ordinary tests can check it |
| 2026-10-08 | Use a GitHub commit status and branch protection for merge safety | GitHub enforces the rule; a local lock is only the fallback |
| 2026-10-08 | Use our own config, labels, result format and defect categories | The project must show original work |
| 2026-10-09 | Name: `trust-factory` | It states the thesis, and almost no other project uses it |
| 2026-10-09 | The repo stays private until Phase 6 | The full history becomes visible when it goes public |
| 2026-10-09 | The check script posts its own commit status context, `agent-works/checks`, for the fixed checks only | A green status must not claim more than the script checked |
| 2026-10-09 | The check script reads the config from the default branch, and the PR must target `branch.base` | A commit status belongs to a commit, not to a PR. A PR into an agent branch could bring its own config and get a green status for a commit that later goes to the base |
| 2026-10-09 | Fail-first runs the verify commands at the merge base with only the PR's test changes; the `verify` check covers "passes with the change" | The config has no command for single tests. At the merge base, the test changes always apply. One cause gives one failed check |
| 2026-10-09 | A base conflict stops the check with `rebuild` before the slow checks | The builder must merge the base first, and then all checks run again |
| 2026-10-09 | Globs are git glob pathspecs | git already matches them, so the script needs no glob code |
| 2026-10-09 | The check script needs git 2.38 or later | `git merge-tree --write-tree` finds conflicts without a scratch merge |
| 2026-10-09 | Start Phase 3 before Phase 2 | The pilot repo is not ready. Phase 3 uses its own fixture repo and does not need the builder |
| 2026-10-09 | A criterion can be `met: null`, and concerns start with their type | The "unsure" result needs a source in the map. A script can check that an injection was reported |
| 2026-10-09 | A false claim in the PR summary makes the result `fail` | A builder that overclaims cannot be trusted, also when the code is correct |
| 2026-10-09 | The verifier uses the model `opus` | The catch rate matters most. Each role has one fixed model |
| 2026-10-09 | The suite runs the verifier with `claude -p`: the agent file as the system prompt, read-only tools, `dontAsk` and a JSON schema | It uses the same agent file. It cannot edit or push. A script can read its output. `claude --agent` ignores `--json-schema` |
| 2026-10-09 | The fixture is a small Python 3.9 package | The tests are fast, portable and easy to read |
| 2026-10-09 | Each seeded PR must pass the fixed checks | Then the suite measures the verifier, not the check script |
| 2026-10-09 | Publish the latest full scorecard in the repo as `trust-suite/scorecard.md` | The scorecard is the main evidence for the thesis. The same commit holds the prompt that made it |
| 2026-10-09 | The pilot is `onishimura/private-pilot`, with the verify commands `npm ci --no-audit --no-fund` and `npm run check` | It is a real project. A full check takes about 20 seconds. Its tests are pure and need Node 24 on `PATH` |
| 2026-10-09 | Skip branch protection on the pilot for now | The pilot is private on a free plan. In `propose` mode a person merges, and the commit status still shows on each PR |
| 2026-10-09 | The builder does not push or open PRs. `build.sh` does | A script enforces the branch prefix and the draft PR. An agent with push rights could push to the base |
| 2026-10-09 | Agents run as `claude -p` processes, with the agent file as the system prompt | The output follows a JSON schema, and it has the cost and the token count for the ledger. Each role gets only its own tools and permission rules. The trust suite runs the verifier the same way |
| 2026-10-09 | The builder's commits have the author "agent-works builder" | The report can find commits by a person |
| 2026-10-09 | Agent sessions load only the project settings | The user's own allow rules must not widen an agent's permissions |
| 2026-10-09 | The builder must not change `PATH` or guess about its environment, and `build.sh` lists the denied commands | In the first pilot run, a denied `export PATH` led the builder to a false claim about the Node version |
| 2026-10-09 | A script (`factory.sh`) is the orchestrator, and the skill only starts it | The decision table is a fixed rule, so a script applies it and offline tests check it |
| 2026-10-09 | The core budget is approximately 720 lines | The orchestrator script (about 150 lines) and the ledger report keep the decisions in tested code. The core was 713 lines at the end of Phase 4 |
| 2026-10-09 | The verifier result gets its own commit status, `agent-works/verifier` | Each status claims only what its step checked. Branch protection can require both |
| 2026-10-09 | The ledger adds one line for each finished attempt; the last line of an issue is its record | The file is append-only, so a stop cannot damage it, and a resume finds the attempt count |
| 2026-10-09 | A resumed issue starts its attempt again from the build | It is simple and correct. A stopped attempt left no ledger line |
| 2026-10-09 | `trust-suite/run.sh` uses `scripts/verify.sh` | The scorecard measures the same verifier step that runs on real PRs |
| 2026-10-09 | Fail-first is skipped for `type:docs` and `type:chore`, also when the PR changes tests | Pilot #17: removed tests "passed without the change". With that feedback, the builder added a test only to make the base fail. The verifier caught it |
| 2026-10-09 | The `needs-person` comment lists the reasons of each attempt, and a blocked builder's summary is one reason | Pilot #17: the comment showed only the last attempt, so the verifier's catch was only in the ledger |
| 2026-10-09 | The report shows one row for each run, not for each issue | Pilot #17 ran twice. A report by issue dropped the failed first run and its cost |
| 2026-10-09 | Keep `propose` mode; do not allow `auto` yet | 9 of 10 pilot issues merged with no human edits, but the pilot has no merge enforcement, the workflow cannot follow a moving base by itself, and the sample is small. See `docs/auto-merge-decision.md` |
| 2026-10-09 | Install by clone: `scripts/setup.sh` prepares the target repo and links the skill into `~/.claude/skills` | It works with the current layout and needs no plugin format. A plugin can come later |
| 2026-10-09 | License: MIT | Short and permissive, for a showcase repo |
| 2026-10-09 | The core budget is approximately 760 lines | The setup script (35 lines) is part of v1 scope. The core is 752 lines |
| 2026-10-09 | A public demo repo, `onishimura/agent-works-demo`, holds the demo and the branch-protection test | The pilot is private on a free plan, so it has no branch protection. The demo shows real output that anyone can open |
| 2026-10-09 | `build.sh` changes `\n` escapes into line breaks when a summary has no line break | Demo run 1: the PR body showed the characters `\n` |
| 2026-10-09 | The credits move from the README to `ACKNOWLEDGMENTS.md`, with each idea linked to the part of the design that uses it | The README stays short, and the credits show how each idea shaped the design |
| 2026-10-09 | Before the repo goes public, the history uses the owner's GitHub no-reply email and calls the pilot `private-pilot` | The owner's email and the name of the private pilot repo must not become public |
| 2026-10-21 | Rename `trust-factory` to `agent-works`. The rename covers the repo, the skill, the config directory `.agent-works/`, the commit status contexts `agent-works/checks` and `agent-works/verifier`, the builder author "agent-works builder" and the `refs/agent-works/` refs. `trust-suite/` and `factory.sh` keep their names | "Trust" claimed too much, and the name did not say that AI agents do the work. "Works" means a place of work and the work itself. The names that the workflow writes follow the project name, so one name is used everywhere |
| 2026-10-21 | `report.py` also counts the old author "trust-factory builder" as the builder | Pilot PRs that merged before the rename have the old author. Without this rule, the report counts them as human edits |
| 2026-10-21 | No fallback for the old config directory `.trust-factory/` | The project is two weeks old and has two known target repos. A repo that used the old name runs `git mv .trust-factory .agent-works` once and updates its required status checks. A fallback would add code for a one-time move |
| 2026-10-21 | Rename the demo repo to `onishimura/agent-works-demo` | It follows the project name. GitHub redirects the old URL, and the branch protection stays as it was |
| 2026-10-21 | The controller can be a person or an AI orchestrator outside agent-works. The design does not depend on one AI; the current scripts run the agents with Claude Code | Owen's decision. No code checks who adds `agent:ready`. The agents in agent-works still never add it, so an agent cannot approve its own work. The controller must treat issue text as data, as the agents do |
| 2026-10-22 | `check.sh` reads the config and the protected paths before the PR's code runs, and it keeps the checks and the reasons in shell variables | An outside review: the PR's test code changed the config and the protected-path list in the check's temp directory. Broken code with a workflow change got three passing checks |
| 2026-10-22 | A config value of the wrong type stops the check with `needs-person` | An outside review: with a string for `checks.verify`, no command ran, and a docs issue got `proposed`. A string for `merge.protected_paths` turned off the protected-path check |
| 2026-10-22 | A `pass` with a concern is not a valid criteria map | Each type of concern gives `fail` or `unsure`. An outside review: the orchestrator accepted a `pass` with a `regression:` concern |
| 2026-10-22 | A failed status, evidence comment, ready state or label after the verifier gives `retry-later`. The label changes before the ledger line | An outside review: these GitHub failures still gave a `proposed` ledger line. A failed label left a ledger line, and the next run built the issue again |
| 2026-10-22 | `run` keeps the issues of a stopped run in its queue until each starts once | An outside review: only the first round took them. With more of them than `limits.concurrent_issues`, the others stayed in `agent:working` |
| 2026-10-22 | `human_edits` is unknown when GitHub does not give the commits | An outside review: a failed request counted as "no human edits", so the report showed too much work without human changes |
| 2026-10-22 | Keep the core budget at approximately 760 lines | The six fixes above add 8 lines. The core is 763 lines |

## Open questions

- Do we keep the state in GitHub issue labels (current design) or in plain markdown files?
- Where do we publish the ledger: in the repo, or only in the README?
- Does the builder use a test-driven development skill when one is installed?
- Do we run the verify commands in an OS sandbox (`sandbox-exec` on macOS, `bwrap` on Linux) that lets them write only in their worktree? This stops the attacks in "Safety". Linux then needs `bwrap`, and some verify commands need more writable paths, for example a package cache.
