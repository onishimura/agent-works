# agent-works

**AI agents that build your GitHub issues, and a measure of how far to trust the result.**

agent-works is a small Claude Code workflow for GitHub repos. A person marks an issue as ready. A builder agent makes the change in its own worktree, and a script opens a draft PR. Fixed checks run first. Then a verifier agent, which cannot edit code, connects each acceptance criterion to evidence. Every run writes a record, and a seeded test suite measures how well the verifier finds bad PRs.

> **Status:** public since 2026-10-09. The whole workflow runs and has offline tests (`tests/run.sh`). One Phase 6 check is open: a first-time user times the quick start. The full design is in [`docs/design.md`](docs/design.md).

## Why

Many agent workflows show that agents can open PRs. Few of them show how often their own "pass" is correct. agent-works makes that number visible:

- **Verifier scorecard:** seeded bad PRs and good PRs give a catch rate and a false-fail rate.
- **Fixed checks first:** new tests must fail without the change and pass with it. Each acceptance criterion must link to evidence.
- **Run ledger:** each run records time, tokens, attempts, results and human edits.

## Results

**Trust suite** ([`trust-suite/scorecard.md`](trust-suite/scorecard.md)). Five seeded bad PRs (a skipped criterion, an overclaiming summary, a weakened test, a silent regression and an injected instruction) and three good controls. In two full runs, the verifier caught 5 of 5 bad PRs and passed 3 of 3 good controls. A run costs about $0.40.

**Pilot** ([`docs/auto-merge-decision.md`](docs/auto-merge-decision.md)). Ten real issues in a private app repo, in 16 runs:

- 9 PRs merged with no human edits, and no merge broke the base branch.
- The verifier caught one PR in which the builder gamed a fixed check. The fixed checks had accepted it.
- One issue went to a person, because its text named facts that the repo does not contain. The builder refused to invent them.
- Total cost: $8.43, about 2.5 minutes for each run.

The workflow stays in `propose` mode: a person merges each PR. The decision document says what must change before `auto` mode.

**Demo** ([`docs/demo.md`](docs/demo.md)). One issue in the public repo [`onishimura/agent-works-demo`](https://github.com/onishimura/agent-works-demo), from `agent:ready` to a proposed PR with its evidence, in about one minute. The quick start took 2 minutes 36 seconds of machine time, to the proposed PR and the scorecard.

## How it works

```text
issue + agent:ready  (a person)
  → build.sh    worktree, builder agent (tests first), draft PR
  → check.sh    fail-first, verify commands, protected paths → commit status agent-works/checks
  → verify.sh   verifier agent: criteria map with evidence → commit status agent-works/verifier
  → factory.sh  decision, labels, evidence comment, ledger line
  → agent:proposed (a person merges) | agent:ready (rebuild) | agent:needs-person
```

- The builder cannot push. `build.sh` pushes only the agent branch.
- The verifier has no edit tools, and it sees the diff and the test output, not only the builder's summary.
- The checks read their config from the default branch, never from the PR.
- Each agent runs as `claude -p` with its own tools, permission rules and a JSON schema for its output.

## Quick start

You need macOS or Linux with Bash 3.2 or later, git 2.38 or later, Python 3.9 or later, `jq`, and `gh` and Claude Code, both logged in.

1. Get agent-works:

   ```bash
   git clone https://github.com/onishimura/agent-works.git ~/agent-works
   ```

2. In a clone of your target repo, run the setup script. It creates the labels, writes `.agent-works/config.json`, ignores the ledger and links the skill. It does not commit.

   ```bash
   ~/agent-works/scripts/setup.sh
   ```

3. Edit `.agent-works/config.json`: the verify commands, the test globs and the protected paths. Commit it and `.gitignore` to the default branch.

4. Write an issue with the sections "Goal", "Acceptance criteria" and "Out of scope". Then mark it as ready:

   ```bash
   gh issue edit 1 --add-label agent:ready
   ```

5. Run the workflow, with the tools for your verify commands on `PATH`. In Claude Code in the target repo, use `/agent-works run`. Or run the script directly:

   ```bash
   ~/agent-works/scripts/factory.sh run
   ```

6. Review the PR and its evidence comment, then merge it. See the results:

   ```bash
   python3 ~/agent-works/scripts/report.py ledger .agent-works/ledger.jsonl
   ```

To see the scorecard, run the trust suite. It uses model tokens, about $0.40 for each run.

```bash
~/agent-works/trust-suite/run.sh
```

For full merge safety, turn on branch protection for the default branch. Require the status checks `agent-works/checks` and `agent-works/verifier`, and require an up-to-date branch.

## Progress

| Phase | Goal | Status |
|---|---|---|
| 0 | Decisions and pilot setup | Done |
| 1 | Check script and result format | Done |
| 2 | Builder agent | Done |
| 3 | Verifier agent and trust suite | Done |
| 4 | Orchestrator and run ledger | Done |
| 5 | Measure on ten real issues | Done |
| 6 | Publish | In progress (first-time user test) |

## Development

```bash
tests/run.sh
```

The tests are offline. They use local git repos and stubs for `gh` and `claude`. The rules for this repo are in [`CLAUDE.md`](CLAUDE.md).

## Acknowledgments

agent-works takes ideas from other projects and articles, but none of their code. [`ACKNOWLEDGMENTS.md`](ACKNOWLEDGMENTS.md) names each source, its idea and where the design uses it.

## License

MIT. See [`LICENSE`](LICENSE).
