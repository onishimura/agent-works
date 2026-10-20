# agent-works

A small Claude Code workflow that builds GitHub issues with agents and measures how much you can trust the result.

**Spec:** read `docs/design.md` before you design, build or change any component. It is the single source of truth for behavior, names, formats and the phase plan. When a change alters any of these, update `docs/design.md` in the same commit, and add a row to its Decisions table for each new decision.

## Clean-room rule

This repo is a public showcase of original work. Write every file from `docs/design.md` and your own reasoning. The projects in `ACKNOWLEDGMENTS.md` are sources of ideas only: do not open, fetch or copy their source code, and do not reuse their names, layouts, config keys, exit codes or eval cases. If a task seems to need another project's code, stop and ask.

## Working rules

- **Phase by phase.** Work on the current phase in `docs/design.md`. A phase is done when its definition of done is true. Then tick its boxes and update the README Progress table.
- **Budget.** The core (skill, agents, scripts, example config) stays under approximately 760 lines, not counting `tests/` and `trust-suite/`. Before you add a feature, name the failure that it fixes.
- **Script first.** When a script can check a fact, write the script; keep model judgment for what a script cannot check.
- **Portable scripts.** Bash 3.2 (the macOS default) and Python 3.9 standard library, plus `git`, `gh` and `jq`.
- **Offline tests.** Each script change comes with tests in `tests/` that use local git repos and a `gh` stub. One command (`tests/run.sh`) runs all tests; run it and see it pass before you report work as done.
- **Writing.** Write documentation in ASD-STE100 Simplified Technical English: short sentences, the active voice, one topic per sentence.
