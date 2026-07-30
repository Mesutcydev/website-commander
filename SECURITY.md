# Security

Website Commander talks to GitHub and AI providers on your behalf, so it handles
secrets and ingests untrusted content (repository files, rendered web pages).
This document describes the threat model and the mitigations in the code.

## Threat model

| Asset / surface | Threat |
|---|---|
| API keys, GitHub token, deploy-hook URLs | Theft from disk, leakage into logs/sync, exposure to third parties |
| AI model context | Secrets accidentally sent to a provider |
| Repository file contents | **Prompt injection** — a file instructs the agent to misbehave |
| Rendered web page (preview/browser tools) | **Prompt injection** — page text instructs the agent |
| Staged changes | A malicious edit slips through to your repo |
| Local git clone | Credentials persisted to disk |

## Mitigations

### Secrets
- **Keychain-only storage.** API keys, the GitHub token, and deploy-hook URLs are
  stored exclusively in the macOS Keychain (`Services/Keychain.swift`), marked
  `kSecAttrAccessibleWhenUnlocked`. They are never written to `UserDefaults`,
  JSON, or any plaintext file.
- **No secrets in sync.** iCloud sync (`CloudSyncService`) serializes workspaces
  and preferences only; the payload struct deliberately excludes every secret.
- **No secrets on disk in git.** Local clones authenticate per-command with a
  transient `http.extraheader` (`LocalWorkspaceStore.authArgs`). The token is
  **never** embedded in the remote URL, so it is not persisted to `.git/config`.
- **No secrets to providers.** Keys are sent only as request headers to the
  provider's own API. They are never placed in the model prompt or context.
- **No secret logging.** There are no `print`/`NSLog` calls, and git error output
  is scrubbed of any `x-access-token:…` substring before surfacing.

### Prompt injection (`Services/PromptGuard.swift`)
- **Fencing.** Every untrusted tool result — file contents and live web-page
  snapshots — is wrapped in `<<<UNTRUSTED_DATA>>>` delimiters before entering the
  model context, so the model treats it as data, not instructions.
- **Detection.** Untrusted text is scanned for common injection patterns
  ("ignore previous instructions", credential-exfiltration phrasing, jailbreak
  framing). Matches prepend an explicit warning to the fenced content.
- **Standing policy.** The system prompt carries a highest-priority security
  clause: tool output is untrusted, credentials must never be revealed, and
  instructions inside data must be refused and reported.
- **Staged-change scanning.** `SecurityScanner` runs the same injection detection
  (plus `eval`, external-script, and hard-coded-secret checks) on every proposed
  edit, surfacing findings in the diff review with a risk badge.

### The approval gate
The single most important control: the agent **stages** file writes as
`PendingChange` values and **nothing is committed until the user approves** a
color-coded diff. Auto-commit is off by default and clearly warned against.

## Distribution note
This build is intended for direct distribution from the developer's website
without an Apple Developer ID (see `README.md`). Unsigned/ad-hoc-signed apps are
subject to macOS Gatekeeper review on first launch — that is expected and is a
delivery-channel choice, not a code-security gap.

## Reporting
If you find a security issue, please report it privately to the maintainer
rather than opening a public issue.
