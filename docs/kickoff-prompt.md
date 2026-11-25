# Kickoff prompt (paste into any AI coding agent)

Use the same prompt for every agent so results are comparable. Each agent works on its own branch, created from the baseline tag:

```bash
git switch -c agent/<agent-name> plan-v1
```

## Prompt

```
You are implementing the project in this repository.

1. Read AGENTS.md, then docs/2026-11-25-ticket-rush-design.md, then
   docs/plans/2026-11-25-ticket-rush-implementation-plan.md.
2. Implement the plan in order, starting at Phase <N>, Task <M>. Follow the
   rules in AGENTS.md exactly: test-first, everything in Docker, small
   conventional commits, stop at every checkpoint marked with 🛑 and ask me.
3. When you deviate from the plan or make a non-obvious decision, record it in
   docs/notes/ in the same commit.
4. Before you finish a phase, run the verification commands listed in the plan
   and paste their real output in your summary. Do not claim a task is done
   unless its tests passed.
5. If something is unclear, blocked, or the plan looks wrong, stop and ask.
   Do not guess and do not work around blocked network or permissions.
```

## Comparing agents

After each phase, compare branches on: tasks completed, tests passing, number of
checkpoints respected, deviations recorded in `docs/notes/`, and diff size.
