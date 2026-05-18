# Security Policy

## Reporting a Vulnerability

**DO NOT file a public GitHub issue for security vulnerabilities.**

Use GitHub Security Advisories: go to the Security tab and click "Report a vulnerability".

### What to expect
- Acknowledgment within 48 hours
- Critical fixes within 7 days
- High severity within 14 days

### Scope
- Rust shared core (crypto, networking, storage)
- Server application
- Flutter client
- Protocol definitions

### Known issues (read before filing)

We track our own crypto-stack risk inventory in [crypto-audit/02-message-loss-surface.md](crypto-audit/02-message-loss-surface.md). If a report duplicates a finding already catalogued there, please link to the entry rather than filing fresh.
