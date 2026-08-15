# After-Audits Audit (post-remediation)

**Date:** 2026-07-09  
**Branch:** `cursor/security-remediation-c7e1`  
**Trigger:** Users found Preview broken after the security remediation. This pass re-audited what the original 20-pass audit covered, what it missed, and what the remediation itself broke — then fixed **all** confirmed open items that can be fixed in-repo.

---

## 1. What the original audit already checked

Named passes (C1–C21 remediation claimed): Injection, Auth, Authorization, Secrets, Errors, Concurrency, Lifecycle, Data access, Hot paths, Memory, External calls, Idempotency, Consistency, Config, Dependencies, Logging, API contracts, Cross-module, Tests, Verification.

**Deferred outside repo (still open):** OAuth redirect allowlisting in provider consoles; commit real `Package.resolved` on a Mac; Keychain under storage pressure on device; Copilot ToS; physical-device PCC.

---

## 2. Blind spots the original audit had

Strong on security intent; weak on product regressions from the fixes and approval UX races (Preview path compare, approval wipe, dual Approve UI, Keychain Bool only in Settings, tip verify `try?`, documented-but-missing batch fallback).

---

## 3. Findings — all in-repo items addressed

### Pass A (user-found + first after-audit)

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| **AA-1** | HIGH | Preview `/var` vs `/private/var` skipped all downloads | **Fixed** |
| **AA-2** | HIGH | Clarifying chat message wiped staged work | **Fixed** (soft-dismiss) |
| **AA-3** | HIGH | PendingChangesBar bypassed gated side effects | **Fixed** |
| **AA-4** | HIGH | Home undo always success haptic | **Fixed** |
| **AA-5** | MEDIUM | `commitBatch` tip verify fail-open | **Fixed** |
| **AA-6** | MEDIUM | `approveAll` missing per-file fallback | **Fixed** |
| **AA-7** | MEDIUM | Double approve race | **Fixed** (`approvalInFlightID`) |
| **AA-8** | MEDIUM | Deploy Keychain Bool ignored | **Fixed** |
| **AA-9** | MEDIUM | Preview empty files on download failure | **Fixed** |
| **AA-10** | LOW | `index.htm` not discovered | **Fixed** |

### Pass B (remaining open items — this commit)

| ID | Severity | Finding | Status |
|----|----------|---------|--------|
| **AA-11** | MEDIUM | 45s tool watchdog killed large `list_files` | **Fixed** (180s + heartbeat for read-only tools) |
| **AA-12** | MEDIUM | No attachment size/MIME caps | **Fixed** (12 MB + allowlist) |
| **AA-13** | MEDIUM | Deploy API raw error bodies | **Fixed** (`DeployJSON.sanitizeErrorBody`) |
| **AA-14** | LOW–MED | Shortcuts could auto-approve | **Fixed** (block exact phrases + pending approval) |
| **AA-15** | LOW–MED | Conversations persist secrets | **Fixed** (`SecretRedactor` on persist) |
| **AA-16** | LOW | Copy without redaction | **Fixed** (redact on copy) |
| **AA-17** | LOW | `customRules` not delimited | **Fixed** (`<untrusted_site_rules>`) |
| **AA-18** | MEDIUM | Preview ignored `rootDirectory` | **Fixed** (remap + GitHub path restore) |
| **AA-19** | MEDIUM | Truncated GitHub trees undetected | **Fixed** (`listRecursiveDetailed` + Preview warning / list_files error) |
| **AA-20** | LOW | `Package.resolved` not committed | **Still needs Mac** (`xcodebuild -resolvePackageDependencies`) |

Conversation save failures now also append a system note when `lastError` is already set.

### Re-confirmed clean

Side-effect gating, POST non-retry, `canAutoApprove` SecurityScan/delete/upload blocks, exact approval phrases, agent `validatePath`, ATS default, Keychain for API keys, DEBUG-only Pro bypass, deploy-hook error sanitization.

---

## 4. Tests

- `testPendingApprovalHasSideEffectsDetectsGatedTools`
- `testSoftDismissApprovalKeepsStagedChanges`
- `testCancelApprovalStillDiscardsStagedChanges`
- `testPreviewURLInsideRootToleratesVarPrivatePrefix`
- `testSecretRedactorMasksTokensAndKeys`
- `testDeployErrorBodySanitizerPrefersMessageAndRedactsBearer`
- `testApprovalPhraseSetsAreExactOnly`

---

## 5. Process recommendation

1. After every sandbox/path change: Preview a real static site.
2. After approval-flow changes: Approve / Reject / clarifying message / Approve-all / gated deploy.
3. Doc comments that promise behavior must match code.
4. Never compare standardized paths to raw paths.
5. Fail closed on post-mutation verification.

---

## 6. Ship note

Marketing **1.11**, build **2026070906**.  
`Package.resolved` still requires a one-time Mac resolve + commit (AA-20).
