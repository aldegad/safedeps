# Security Policy

safedeps is a security tool, so it holds itself to the posture it enforces: local-only, no SaaS, **zero runtime npm dependencies**, fail-closed gates, and observable bypasses.

## Supported versions

| Version | Supported |
|---|---|
| 2.x (latest minor) | ✅ |
| < 2.0 (`npm-reorg-guard`) | ❌ — migrate with `safedeps migrate` |

Fixes land on the latest minor. Pin to a released tag for reproducibility.

## Reporting a vulnerability

**Do not open a public issue for a vulnerability.** Report it privately:

1. **Preferred** — GitHub private advisory: the repo's **Security → Report a vulnerability** tab (<https://github.com/aldegad/safedeps/security/advisories/new>).
2. **Email** — `aldegad@gmail.com` with `[safedeps security]` in the subject.

Please include: affected version (`safedeps --json version`), a minimal reproduction, the impact (e.g. a gate bypass, a fail-open path, a reorg that misses a threat), and any logs from `~/.safedeps/advisory.log` / `~/.safedeps/reorg.log`.

### What counts

In scope — anything that defeats a gate or weakens its guarantees, for example:

- a dependency-install command that bypasses the PreToolUse guard or the PostToolUse effect gate;
- a malicious package whose closure or install scripts pass verification when they should reorg;
- a **fail-open** path (a gate that silently passes when it cannot run);
- a secret-leak lane bypass (a committed secret the scaffolded gate misses);
- ledger tampering that grants an unapproved spec (note: the ledger is a same-user convenience cache, **not** a boundary against a same-user attacker until signing lands — that limit is documented, not a vuln).

Out of scope — issues requiring an already-root/same-user attacker beyond the documented threat model, or third-party advisory-database accuracy (OSV/KEV/GHSA own their data).

## Response

- Acknowledgement within ~72 hours.
- A fix or mitigation plan for confirmed reports, coordinated before public disclosure.
- Credit in the release notes if you'd like it.

## Security properties (by design)

- **No SaaS** — local CLI + public databases (OSV / CISA KEV / GHSA) only.
- **Zero npm dependencies** — the tool ships no runtime deps; this is a deliberate security property, kept enforced by `npm pack` review in CI.
- **No silent fallback** — a provider/scanner miss is fail-closed; any unavoidable bypass is recorded in `~/.safedeps/advisory.log`.
