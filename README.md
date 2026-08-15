# Website Commander

A native **macOS** app that lets you manage and edit your websites with plain
English. Connect a GitHub repository, tell the AI agent what to change, review a
visual diff, approve it, and watch it commit and deploy — all from a calm,
visual, Mac-first interface.

Website Commander is the open-source, Mac-native reimagining of the SiteAgent
workflow. It is distributed directly from the developer's website (no App Store),
runs entirely on your machine, and keeps your credentials in the macOS Keychain.

---

## Highlights

- **Natural-language editing** — describe a change; the agent reads your repo,
  writes the edits, and stages them for your approval.
- **Visual-first UI** — a Mac sidebar shell, a visual Command Center, icon-driven
  controls, and side-by-side diffs. Designed to be read at a glance, not studied.
- **Approval gate** — nothing is committed until you approve it. Every change
  shows a color-coded diff and a security risk scan.
- **Multi-provider AI** — OpenAI, Anthropic (Claude), DeepSeek, Grok, Mistral,
  Gemini, GitHub Copilot, or any OpenAI-compatible endpoint. Smart auto-routing
  picks a model per task.
- **Live preview** — render the site with staged changes applied, in mobile /
  tablet / desktop viewports.
- **VSCode-native workflow** — each site is a local git clone. One click opens it
  in VSCode; edits you make there are picked up by the agent.
- **Private by design** — direct API calls, no proxy servers, no telemetry. Keys
  live in the Keychain.

---

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15+ to build
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the project
- [VSCode](https://code.visualstudio.com/) with the `code` CLI on your PATH
  (optional, for the Open-in-VSCode feature)

## Website

The public marketing site lives in [`website/`](website/) and is the canonical source for the Website Commander Pages deployment. The portfolio app page is [`mesut.uk/apps/website-commander`](https://mesut.uk/apps/website-commander). It is a dependency-free static site with a responsive command-deck design, real app screenshots, and a privacy overview.

Validate and preview it locally:

```bash
./Scripts/check-website.sh
python3 -m http.server 8080 --directory website
```

The Pages workflow in `.github/workflows/pages.yml` deploys it from `main` when GitHub Pages is configured for GitHub Actions. The portfolio entry at `https://mesut.uk/apps/website-commander` points to this canonical site. See [`docs/github-pages-sync.md`](docs/github-pages-sync.md) for the separate `<owner>.github.io` synchronization path.

## Build

```bash
xcodegen generate
open WebsiteCommander.xcodeproj      # or:
xcodebuild -scheme WebsiteCommander -configuration Debug build
```

The project builds with **no external dependencies** for the core app. Signing is
optional for local runs — verify a clean compile with:

```bash
xcodebuild -scheme WebsiteCommander -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

## First run

1. Launch Website Commander and finish the welcome tour.
2. Open **Settings → GitHub** and sign in (or paste a personal access token with
   `repo` scope).
3. Open **Settings → AI Provider**, pick a provider, and paste its API key.
4. Click **+ New Site**, choose one of your repositories, and pick a tech stack.
5. Go to the **Agent**, type a request, review the diff, and approve.

---

## Architecture

```
WebsiteCommander/
├── App/                 @main, window scene, sidebar root
├── DesignSystem/        Theme + reusable visual components
├── Models/              Workspace, repo, chat, pending-change, commit models
├── Services/            Keychain, settings store, GitHub client/auth,
│                        local workspace (git) store, VSCode bridge
├── Providers/           LLM provider protocol + concrete providers + registry
├── Engine/              AgentEngine: tool-use loop, staging, approval, commit
└── Views/               CommandCenter, Sites, Chat, Diff, Preview, History,
                         Settings, Onboarding
```

The **AgentEngine** runs the provider's tool-use loop. File writes are *staged*
as `PendingChange` values and only committed when the user approves — that is the
safety gate. Read-only tools (list, read, search) run freely; mutating tools
require approval.

## What's implemented

- **Core loop** — connect → chat → stage → visual diff + security scan → approve &
  commit → live preview → history → open in VSCode.
- **Multi-site, multi-account** — connect many sites, each bound to its own GitHub
  account; a polished popover site switcher in the sidebar.
- **Multi-provider AI** — OpenAI, Claude, Gemini, DeepSeek, Grok, Mistral, Copilot,
  custom endpoints, plus **on-device** inference via Apple's Foundation Models
  (macOS 26+, no network, no key). Smart auto-routing per task.
- **Live web inspector** — console, network, performance, element picker.
- **Site audit** — client-side SEO/accessibility/performance/runtime checks with a
  health score; **Analyze with AI** and **Fix with AI** hand findings to the agent.
- **Smart debugger + agent export** — one click consolidates every breadcrumb
  (console errors, failed requests, perf, audit, prompt-injection flags, repo path)
  into a *debug brief* you can open in VS Code/Cursor, copy as a tailored prompt for
  Codex/Claude/opencode, launch in Terminal, or send to the in-app agent.
- **Real brand marks** — official provider logos as true vectors, used the
  trademark-compliant way (see `BrandMark.swift`).
- **Deployment** — auto-redeploy notes plus deploy-hook triggers for Cloudflare
  Pages, Vercel and Netlify.
- **iCloud sync** of workspaces & preferences (secrets never sync).
- **CLI for agents** — a headless `wc` binary so other agents can drive the app.

## CLI — let other agents use Website Commander

The `wc` tool shares the GUI's settings and Keychain, so once you've configured a
GitHub token and provider in the app, any agent (Codex, Cursor, opencode, Claude, a
shell script…) can drive it:

```bash
wc sites add --name "My Portfolio"     # auto-detects owner/repo/stack/deploy from cwd
wc debug --for claude                  # writes a debug brief + prints an agent prompt
wc use "My Portfolio" add a contact form --approve
wc sites                               # JSON list
wc providers                           # JSON list
```

`wc sites add` infers the repository from the current checkout (git remote + branch,
`package.json`/config heuristics for the stack, `vercel.json`/`wrangler.toml`/… for
the host), so an agent can simply run it inside a repo. `wc debug` writes
`.website-commander/debug-brief.md` into the repo and prints a ready prompt to
stdout — point any agent at it and it has the full picture.

## Security

See [SECURITY.md](SECURITY.md). In short: secrets live only in the Keychain
(`kSecAttrAccessibleWhenUnlocked`), git clones authenticate per-command so tokens
never touch `.git/config`, nothing syncs to iCloud, and untrusted content (repo
files, rendered pages) is fenced and scanned for prompt injection before it reaches
a model. Nothing is ever committed without your approval.

## Distributing without a Developer ID

This app is built to ship straight from your website — no App Store, no Developer
ID required:

```bash
./Scripts/build-release.sh
```

The script builds a Release `.app`, bundles the `wc` CLI inside it, **ad-hoc signs**
it (`codesign --sign -`), and emits a `.dmg`, a `.zip`, and a `SHA256SUMS.txt`.
Publish the checksums alongside the downloads so users can verify them.

Because the build is ad-hoc (not notarized), macOS Gatekeeper will flag it on first
launch — that's expected, not a code problem. Users open it once via
**right-click → Open**, or in Terminal:

```bash
xattr -cr /Applications/WebsiteCommander.app
ln -sf "/Applications/WebsiteCommander.app/Contents/SharedSupport/wc" /usr/local/bin/wc
```

If you later regain a Developer ID, the same project notarizes normally — just sign
with your identity instead of `-` and run `xcrun notarytool submit …`.

## Roadmap

- On-device model catalog UI (download/switch local models) — the runtime path
  exists via Foundation Models; a richer picker is the next polish.
- Streaming token output in the chat (currently whole-turn).
- Per-site agent memory / saved conversations.
- A VS Code / Cursor extension that talks to the running app over a local socket.

## Typography

App chrome is set in a neo-grotesque rather than the system font. The family is
resolved at runtime, in order:

1. **Die Grotesk** (Klim Type Foundry) — the reference face. It's a commercial
   retail family, so this repository can't ship it; if you've licensed it and
   installed it into `~/Library/Fonts`, the app picks it up automatically with
   no configuration.
2. **Hanken Grotesk** — the bundled default (`WebsiteCommander/Resources/Fonts`),
   same Helvetica/Akzidenz lineage, slightly more open apertures for screen use.
3. **Helvetica Neue**, then the system font, as fallbacks.

Code, diffs, and terminal output stay monospaced. See
`WebsiteCommander/DesignSystem/Typography.swift`.

## License

MIT — see [LICENSE](LICENSE).

Hanken Grotesk © 2021 The Hanken Grotesk Project Authors, licensed under the
SIL Open Font License 1.1 — see
[WebsiteCommander/Resources/Fonts/OFL.txt](WebsiteCommander/Resources/Fonts/OFL.txt).
