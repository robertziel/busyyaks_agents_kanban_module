# Security policy

## Reporting a vulnerability

Report it **privately**, through GitHub's private vulnerability reporting:
[Security → Report a vulnerability](https://github.com/robertziel/busyyaks_agents_kanban_module/security/advisories/new).
Never in a public issue, pull request or discussion.

Include what you can of: the commit, the part of the module (`Store`, `Api`, `Tools`, `Attachments`, `Markdown`,
`SessionDialog`, `Notifier`, `Launch`, the React board), the host config it needs, steps to reproduce, and the
impact you expect. A problem you found through busyyaks can be reported in either repo.

What happens next:

| | |
|---|---|
| Acknowledgement | within 7 days |
| Assessment | confirmed or declined with the reason, in the advisory |
| Fix | developed in the advisory's temporary private fork, merged with the advisory published and a CHANGELOG entry; busyyaks re-vendors it at once |
| Credit | in the advisory and the CHANGELOG, unless you ask not to be named |

## Supported versions

Hosts vendor the module at a commit (a release tag or `main`); there are no packages.

| Version | Supported |
|---|---|
| `1.0.0-beta.x` (the latest beta) and `main` | yes: fixes land on `main` and ship in the next beta |
| an older release or commit | no: re-vendor the commit that carries the fix |

## Scope

In scope: what the module itself enforces and renders.

- the gates: an agent (MCP) moving a card past what its transitions allow, into a column only the operator may move
  it to, or approving its own work; `kanban_ask` / `kanban_handoff` / `kanban_claim` checks; card ownership and the
  session registry;
- the operator API (`Api`) and the MCP tools (`Tools`): input validation, refusals, data of another board or
  project leaking through them;
- server-side Markdown rendering (raw HTML dropped) and the React board: script injection into the board or card
  dialog;
- attachments: type detection, size and type limits, paths on disk;
- `SessionDialog` and `Notifier`: what is typed or pressed into an agent's terminal, and when;
- `Launch`: the argv and prompt built from host config and card data.

Out of scope:

- **Who the operator is.** The module trusts the identity its host passes in (`by:`); authentication, sessions,
  CSRF and the network exposure are the host's. For busyyaks, its `auth: none` exposed beyond localhost is out of
  scope by design (every request is the operator; see busyyaks's SECURITY.md).
- The host's own transport to tmux (busyyaks's launcher socket) and the commands its config lists as launchers.
- What an agent session does with the access its host gave it.
- Vulnerabilities in third-party dependencies with no module-specific impact: report them upstream.
