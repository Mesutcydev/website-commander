# SiteAgent 1.16

## What’s New

SiteAgent’s biggest workflow upgrade yet makes long, connected website work faster, safer, and easier to continue:

- Smarter long-session context management, repeated-tool loop protection, reasoning effort controls, and transparent model fallback.
- Independent repository reads can run in parallel while writes remain safely serialized and staged for approval.
- Searchable and pinnable conversation history, launch preferences, workspace Site Profiles, deep links, and an opt-in record-level iCloud Sync beta.
- A new Image Studio creates website assets with GPT Image 2 or edits an existing image, then adds the original bytes to the normal chat, preview, and approval flow.
- Curated MCP integrations and workspace Skills add permissioned external tools without bypassing SiteAgent’s safety gates.
- Mount external folders, manage persistent shared files, preview Markdown/HTML/images, and export or import provider settings without secrets.
- Custom preview dimensions and user-agent overrides, attachment drag reordering, and automatic file handling for very long pasted text.
- Provider-import audit history, one-tap revert, secret masking in model-visible tool output, and extensive stability improvements.

API keys, OAuth tokens, and GitHub credentials remain in Keychain and are never included in configuration exports or iCloud sync.

## What to Test

1. In Settings → Behavior & Theme, change Agent effort, launch behavior, model fallback, and secret masking.
2. In chat, add multiple attachments, reorder them, and open Create or Edit Image. Verify the created image returns as a normal attachment and is not committed without approval.
3. Open chat history, pin a conversation, search by workspace/message/path, then relaunch using the Last Conversation preference.
4. In Settings → Workspace & Portability, import and preview a shared file, export provider configuration, import it, and use Revert. Confirm credentials are unchanged.
5. Enable record-level iCloud Sync (Beta) on two devices signed into the same iCloud account. Verify small workspaces/conversations sync independently and deletion propagates. Verify an oversized record stays local with a warning.
6. In Settings → Extensibility, edit the Site Profile, enable a Workspace Skill, and add an HTTPS MCP endpoint. Confirm write-capable MCP tools still require their configured permission.
7. Open a website preview, choose Custom, set dimensions and a user agent, and verify the preview resizes and displays the Custom UA indicator.
8. Run a multi-file task and verify parallel reads preserve ordered results, staged changes still require approval, fallback is shown if a provider fails, and repeated tool loops stop with a clear message.

Notes for review:

- OpenAI Image Studio requires the reviewer to connect OpenAI or enter their own OpenAI API key; generation may incur charges from OpenAI.
- MCP testing requires a reviewer-supplied HTTPS MCP endpoint.
- iCloud Sync is off by default and intentionally excludes secrets.
- Core GitHub editing requires a repository and GitHub write credential. The built-in Guided Demo can be used to inspect the local staged-change review flow without committing.
