# Repository working instructions

## Delivery

- Work requested by the owner is delivered directly to `main` by default. Create a
  pull request only when the owner explicitly asks for one. Do not leave completed
  work on a feature branch waiting for review.
- Inspect the working tree and remote state before integrating changes. Preserve
  unrelated or pre-existing changes, and stage only changes intended for the task.
- Commit intentional changes before reporting progress or results about those
  changes. Read-only work does not require a commit.
- Push each completed commit promptly to the corresponding remote branch. Local
  commits alone are not delivery. Report any push failure immediately.
- Preserve history with normal commits and merges. Delete only fully merged,
  task-owned branches, and finish on a clean, synchronized `main` when possible.

## Validation

- Select checks from the behavior changed, following `CONTRIBUTING.md`. Text-only
  edits do not require Swift suites, simulator runs, or paid model calls.
- Reuse existing successful validation when integrating unchanged code. Rerun
  checks when conflicts, code changes, failures, or unresolved risks justify them.
- Evaluate autonomous workflows through mobileLLM's production execution path.
  Keep task answers and outcome oracles in evaluation code, and retain failures.
