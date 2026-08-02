import * as vscode from "vscode";
import * as net from "net";
import * as fs from "fs";
import * as path from "path";
import * as os from "os";

// VS Code extension that talks to the running Website Commander macOS app over
// its loopback agent bridge (see WebsiteCommander/Services/LocalBridge.swift).
// The bridge must be enabled in the app (Settings → Local Agent Bridge); the
// extension reads the token + port the app publishes and authenticates with them.

interface BridgeResponse {
  ok?: boolean;
  error?: string;
  sites?: Array<{ name: string; slug: string; active?: boolean }>;
  reply?: string;
  committed?: number;
  staged?: number;
  markdown?: string;
  prompt?: string;
  briefPath?: string;
  healthScore?: number;
  liveURL?: string;
  audit?: Array<{ severity: string; title: string; detail: string }>;
  consoleErrors?: string[];
  failedRequests?: Array<{ method: string; url: string; status: number }>;
  [k: string]: unknown;
}

function supportDir(): string {
  const override = vscode.workspace
    .getConfiguration("websiteCommander")
    .get<string>("supportDir", "")
    .trim();
  if (override) return override;
  return path.join(os.homedir(), "Library", "Application Support", "WebsiteCommander");
}

function readText(file: string): string {
  return fs.readFileSync(file, "utf8").trim();
}

function configuredSite(): string {
  return vscode.workspace.getConfiguration("websiteCommander").get<string>("site", "").trim();
}

// One authenticated request per connection, newline-delimited (matches the app).
function request(op: string, params: Record<string, unknown> = {}): Promise<BridgeResponse> {
  return new Promise((resolve, reject) => {
    const dir = supportDir();
    let port: number;
    let token: string;
    try {
      port = parseInt(readText(path.join(dir, "bridge.port")), 10);
      token = readText(path.join(dir, "bridge.token"));
    } catch {
      reject(
        new Error(
          "Website Commander bridge isn't running. Open the app → Settings → " +
            "Local Agent Bridge and turn it on."
        )
      );
      return;
    }
    if (!port || !token) {
      reject(new Error("Website Commander bridge token/port not found."));
      return;
    }

    const socket = net.createConnection({ host: "127.0.0.1", port });
    let buf = "";
    let authed = false;
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error("Website Commander bridge timed out."));
    }, 120000);

    const finish = (resp: BridgeResponse) => {
      clearTimeout(timer);
      socket.destroy();
      resolve(resp);
    };

    socket.on("connect", () => socket.write(`AUTH ${token}\n`));

    socket.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      let nl = buf.indexOf("\n");
      while (nl >= 0) {
        const line = buf.slice(0, nl).replace(/\r$/, "");
        buf = buf.slice(nl + 1);
        if (!authed) {
          authed = true;
          if (line !== "OK") {
            clearTimeout(timer);
            socket.destroy();
            reject(new Error(`Website Commander rejected the token (${line}).`));
            return;
          }
          socket.write(JSON.stringify({ op, ...params }) + "\n");
        } else {
          try {
            finish(JSON.parse(line) as BridgeResponse);
          } catch {
            clearTimeout(timer);
            socket.destroy();
            reject(new Error("Website Commander returned a malformed response."));
          }
          return;
        }
        nl = buf.indexOf("\n");
      }
    });

    socket.on("error", (err) => {
      clearTimeout(timer);
      reject(new Error(`Website Commander bridge error: ${err.message}`));
    });
  });
}

async function pickSite(): Promise<string | undefined> {
  const fixed = configuredSite();
  if (fixed) return fixed;
  try {
    const resp = await request("sites");
    const sites = resp.sites ?? [];
    if (sites.length === 0) {
      vscode.window.showWarningMessage("No sites connected in Website Commander.");
      return undefined;
    }
    const choice = await vscode.window.showQuickPick(
      sites.map((s) => ({ label: s.name, description: s.slug, detail: s.active ? "active" : "" })),
      { placeHolder: "Which site?" }
    );
    return choice ? `${choice.label}` : undefined;
  } catch (e) {
    vscode.window.showErrorMessage((e as Error).message);
    return undefined;
  }
}

async function sendSelection() {
  const editor = vscode.window.activeTextEditor;
  if (!editor) {
    vscode.window.showWarningMessage("Open a file first.");
    return;
  }
  const sel = editor.document.getText(editor.selection);
  const file = path.basename(editor.document.fileName);
  const instruction = await vscode.window.showInputBox({
    prompt: "What should the agent do with this?",
    placeHolder: "e.g. fix the bug / explain / refactor",
  });
  if (!instruction) return;
  const site = await pickSite();
  if (!site) return;
  const context = sel
    ? `In file ${file}, the user selected:\n\`\`\`\n${sel}\n\`\`\`\n\n`
    : `In file ${file}:\n\n`;
  const prompt = `${context}Please: ${instruction}`;
  const approve =
    (await vscode.window.showQuickPick(["Stage only (review in app)", "Approve & commit"], {
      placeHolder: "Commit now or stage for review?",
    })) === "Approve & commit";
  try {
    const resp = await request("use", { site, prompt, approve });
    if (resp.ok) {
      const note = approve ? `committed ${resp.committed ?? 0}` : `staged ${resp.staged ?? 0}`;
      vscode.window.showInformationMessage(`Website Commander: ${note}. ${resp.reply ?? ""}`.slice(0, 300));
    } else {
      vscode.window.showErrorMessage(`Website Commander: ${resp.error ?? "failed"}`);
    }
  } catch (e) {
    vscode.window.showErrorMessage((e as Error).message);
  }
}

async function debugSite() {
  const site = configuredSite() || (await pickSite());
  if (!site && !configuredSite()) return;
  try {
    const resp = await request("debug", site ? { site } : {});
    if (!resp.ok) {
      vscode.window.showErrorMessage(`Website Commander: ${resp.error ?? "failed"}`);
      return;
    }
    const doc = await vscode.workspace.openTextDocument({
      content: resp.markdown ?? "",
      language: "markdown",
    });
    await vscode.window.showTextDocument(doc, { preview: true });
    if (resp.prompt) {
      await vscode.env.clipboard.writeText(resp.prompt);
      vscode.window.showInformationMessage(
        "Debug brief opened; a tailored prompt is on your clipboard."
      );
    }
  } catch (e) {
    vscode.window.showErrorMessage((e as Error).message);
  }
}

async function openPreview(inspect = false) {
  const site = configuredSite() || (await pickSite());
  if (!site && !configuredSite()) return;
  try {
    const resp = await request(inspect ? "inspect" : "preview", site ? { site } : {});
    if (!resp.ok) {
      vscode.window.showErrorMessage(`Website Commander: ${resp.error ?? "failed"}`);
      return;
    }
    vscode.window.showInformationMessage(
      `Website Commander: ${inspect ? "Inspector" : "Preview"} opened${site ? ` for ${site}` : ""}.`
    );
  } catch (e) {
    vscode.window.showErrorMessage((e as Error).message);
  }
}

async function auditPreview() {
  const site = configuredSite() || (await pickSite());
  if (!site && !configuredSite()) return;
  try {
    const resp = await request("audit", site ? { site } : {});
    if (!resp.ok) {
      vscode.window.showErrorMessage(`Website Commander: ${resp.error ?? "failed"}`);
      return;
    }

    const findings = resp.audit ?? [];
    const failedRequests = resp.failedRequests ?? [];
    const errors = resp.consoleErrors ?? [];
    const lines = [
      "# Website Commander Preview Audit",
      "",
      `- Site: ${site ?? "active site"}`,
      `- Live URL: ${resp.liveURL ?? "—"}`,
      `- Health score: ${resp.healthScore ?? 0}/100`,
      "",
      "## Findings",
      "",
      ...(findings.length
        ? findings.map((f) => `- **[${f.severity}] ${f.title}** — ${f.detail}`)
        : ["- No findings." ]),
      "",
      "## Console errors",
      "",
      ...(errors.length ? errors.map((error) => `- ${error}`) : ["- None." ]),
      "",
      "## Failed requests",
      "",
      ...(failedRequests.length
        ? failedRequests.map((request) => `- ${request.method} ${request.url} → ${request.status}`)
        : ["- None." ]),
    ];
    const doc = await vscode.workspace.openTextDocument({
      content: lines.join("\n"),
      language: "markdown",
    });
    await vscode.window.showTextDocument(doc, { preview: true });
  } catch (e) {
    vscode.window.showErrorMessage((e as Error).message);
  }
}

async function listSites() {
  try {
    const resp = await request("sites");
    const sites = resp.sites ?? [];
    if (sites.length === 0) {
      vscode.window.showInformationMessage("No sites connected.");
      return;
    }
    const items = sites.map((s) => `${s.active ? "* " : "  "}${s.name}  (${s.slug})`);
    const doc = await vscode.workspace.openTextDocument({
      content: "Website Commander sites\n\n" + items.join("\n"),
      language: "text",
    });
    await vscode.window.showTextDocument(doc, { preview: true });
  } catch (e) {
    vscode.window.showErrorMessage((e as Error).message);
  }
}

export function activate(context: vscode.ExtensionContext) {
  context.subscriptions.push(
    vscode.commands.registerCommand("websiteCommander.sendSelection", sendSelection),
    vscode.commands.registerCommand("websiteCommander.debugSite", debugSite),
    vscode.commands.registerCommand("websiteCommander.openPreview", () => openPreview(false)),
    vscode.commands.registerCommand("websiteCommander.inspectPreview", () => openPreview(true)),
    vscode.commands.registerCommand("websiteCommander.auditPreview", auditPreview),
    vscode.commands.registerCommand("websiteCommander.listSites", listSites)
  );
}

export function deactivate() {}
