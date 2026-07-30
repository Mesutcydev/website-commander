# Website Commander — VS Code extension

Lets VS Code / Cursor drive the **Website Commander** macOS app: send the current
file or selection to the agent, or pull a debug brief for the site you have open.

It talks to the app over its **loopback agent bridge** — the same surface the
`wc` CLI exposes — so the app must be running with the bridge enabled.

## Prereqs

1. In the Website Commander app: **Settings → Local Agent Bridge → Allow local
   agent connections**. The app writes `bridge.token` (mode `0600`) and
   `bridge.port` to `~/Library/Application Support/WebsiteCommander/`.
2. The site you want to target is connected in the app (or set
   `websiteCommander.site` to a name / `owner/repo`).

## Build & install (local)

```bash
cd extensions/vscode
npm install
npm run compile
npx @vscode/vsce package      # produces website-commander-0.1.0.vsix
code --install-extension website-commander-0.1.0.vsix
```

(For Cursor, use `cursor --install-extension …`.)

## Commands

| Command | What it does |
|---|---|
| **Website Commander: Send selection to agent** | Sends the selection (or whole file) plus your instruction to the agent; you choose *stage* or *approve & commit*. |
| **Website Commander: Debug current site** | Opens the app's debug brief (console/network/audit/repo path) in a tab and copies a tailored prompt to the clipboard. |
| **Website Commander: List sites** | Shows connected sites. |

## Settings

- `websiteCommander.site` — name or `owner/repo` to target (else you're prompted).
- `websiteCommander.supportDir` — override the support dir if the app isn't in the default location.

## Security

The extension only ever connects to `127.0.0.1` and authenticates with the token
the app wrote for the current user. Nothing leaves the machine. If the bridge is
off, every command fails fast with a clear message.
