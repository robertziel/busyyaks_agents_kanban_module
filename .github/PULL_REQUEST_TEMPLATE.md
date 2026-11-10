<!-- Read CONTRIBUTING.md first. A security fix: report it privately (SECURITY.md) before opening a PR. -->

## What and why

<!-- What changes for a host, an operator or an agent, and why. Link the issue: Fixes #… -->

## How it was tested

- [ ] `scripts/ci/test.sh all` is green (lint · ruby-sqlite · ruby-pg · react · secrets)
- [ ] a test that fails without this change (fix) or covers what it does and refuses (feature)
- [ ] both ports and `fixtures/` agree; `SPEC.md` updated if a rule changed
- [ ] no check excluded, skipped, disabled or loosened to pass
- [ ] no host specifics in code: a host difference is a documented key in `config.example.yml`
- [ ] README, `SPEC.md`, `config.example.yml` and `CHANGELOG.md` (`Unreleased`) updated where hosts would notice

## Host impact

<!-- What a host must do when it re-vendors past this: a new Schema step, a new config key, a changed API. "None" is fine. -->

## Screenshots

<!-- Any change to the board's UI: before and after, desktop and phone width. Otherwise: "no UI change". -->
