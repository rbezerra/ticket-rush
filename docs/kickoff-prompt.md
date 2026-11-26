# Kickoff prompt (paste into any AI coding agent)

Work is shared between agents: any agent (or human) can pick up where the
previous one stopped. Branches are named after the **feature** being built, not
after the agent. See "Branching and handoff" in `AGENTS.md`.

Find where to resume:

```bash
git fetch origin
git branch -r --list 'origin/feature/*'   # open feature branches
cat docs/notes/progress.md                # newest entry first: what is done, what is next
```

## Prompt

```
You are continuing the project in this repository. Other agents may have
worked on it before you; the repository is the only shared memory.

1. Read AGENTS.md, then docs/notes/progress.md (newest entry first), then
   docs/2026-11-25-ticket-rush-design.md, then
   docs/plans/2026-11-25-ticket-rush-implementation-plan.md.
2. Resume at the task named in the newest progress entry, on the feature
   branch it names (or create the next feature branch as described in
   AGENTS.md). Follow the rules in AGENTS.md exactly: test-first, everything
   in Docker, small conventional commits, stop at every checkpoint marked
   with 🛑 and ask me.
3. When you deviate from the plan or make a non-obvious decision, record it in
   docs/notes/ in the same commit.
4. Before you finish a phase, run the verification commands listed in the plan
   and paste their real output in your summary. Do not claim a task is done
   unless its tests passed.
5. Before you stop (finished, blocked, or out of budget), add a handoff entry
   at the top of docs/notes/progress.md, commit it, push the feature branch,
   and open a Pull Request against `main` for the owner to review.
6. If something is unclear, blocked, or the plan looks wrong, stop and ask.
   Do not guess and do not work around blocked network or permissions.
```

## Reviewing progress

After each phase, review the feature branch on: tasks completed, tests passing,
checkpoints respected, deviations recorded in `docs/notes/`, and diff size. The
`Agent:` line in each progress entry shows who did which part.
