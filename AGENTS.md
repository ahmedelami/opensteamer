# Agent Guidelines

## Commits

Every commit message should include a concise `Why:` section and a concise `What:` section.

- `Why:` explains the reason for the change: the problem, requirement, or tradeoff.
- `What:` summarizes the implementation at a level where a reviewer can understand the shape of the change.
- Keep both sections short by default. Add detail only when it is needed to understand the change.
- Keep commits focused on one concern. Split unrelated app, server, tooling, documentation, and verification changes.
- Prefer commits that can be reviewed independently and preserve useful checkpoints.

## Code Comments

Prefer self-documenting names and structure over comments.

- Add comments only when local context, a non-obvious constraint, or a platform/API quirk would otherwise be easy to miss.
- Keep comments short and factual.
- Do not narrate code that is already clear from names and types.
