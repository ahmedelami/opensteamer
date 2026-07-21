# Contributing

## Documentation standard

Use names and types to explain the ordinary control flow. Add documentation
where a reader cannot safely infer the contract from syntax alone:

- `///` comments describe module-facing Swift and Objective-C APIs, ownership,
  units, error semantics, and concurrency requirements.
- JSDoc describes exported JavaScript functions, request/response shapes, and
  thrown or rejected conditions.
- Inline comments explain security boundaries, lifecycle transitions, platform
  quirks, wire compatibility, timing assumptions, and intentionally unusual
  code. Do not narrate obvious assignments or branches.
- Test comments name the independent oracle, the regression being prevented,
  and why a fixture is safe. They should not repeat every assertion.
- Operational scripts document usage, prerequisites, environment variables,
  side effects, generated artifacts, and exit-status meaning near the entry
  point.

Keep comments factual and update them in the same change as the behavior they
describe. Do not use comments to preserve obsolete implementation history; Git
already records that history.

## Secret hygiene

Use only synthetic, visibly non-production fixtures. Never copy a value from a
running app, Keychain, environment, cloud dashboard, provisioning profile, log,
or screenshot into source or test data. Local `.env`, `.dev.vars`, signing-key,
and provisioning files are ignored; example configuration must contain obvious
placeholders only.

Before publishing a branch, scan both its current tree and its complete Git
history. A clean working tree scan cannot detect a secret retained by an older
commit or pull-request ref.

## Validation

Run the narrowest tests that exercise the changed contract, followed by the
owning package's broader suite. Release claims must satisfy the independent
oracles in `TESTING_ORACLES.md`; a source string, mocked state transition, or
stale artifact is not production evidence.
