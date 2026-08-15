import Foundation

/// A starter site the "Create Site" flow seeds into a brand-new repo. Vanilla
/// templates are self-contained static HTML (no build step). Framework
/// templates ship minimal `package.json` + config + one page.
///
/// ponytail: single-file `index.html` per template (styles inlined). One file
/// means no relative-CSS-path edge cases when Pages serves a project site at
/// `/{repo}/`, and the agent can still edit it freely afterwards. Every template
/// ships SEO-ready (`<title>`, meta description, Open Graph, viewport) so a new
/// site is presentable even before the AI touches it.
struct SiteTemplate: Identifiable, Hashable {
    let id: String
    let name: String
    let tagline: String
    let icon: String            // SF Symbol, for the picker
    let techStack: TechStack
    /// Raw files (path -> contents). `{{SITE_NAME}}` is substituted at create time.
    private let rawFiles: [String: String]

    /// Files with the site name substituted in, ready for `commitBatch`.
    func files(siteName: String) -> [String: String] {
        let safe = siteName.isEmpty ? "My Site" : siteName
        let slug = Self.slugify(safe)
        return rawFiles.mapValues {
            $0.replacingOccurrences(of: "{{SITE_NAME}}", with: safe)
                .replacingOccurrences(of: "{{SITE_NAME_SLUG}}", with: slug.isEmpty ? "my-site" : slug)
        }
    }

    static let all: [SiteTemplate] = [portfolio, landing, blog, docs, astroMinimal, nextStatic]

    private static func slugify(_ raw: String) -> String {
        let mapped = raw.lowercased().map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
        }
        var slug = String(mapped)
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

// MARK: - Host config scaffolds (Vercel / Netlify on create)

enum HostConfigFiles {
    /// Minimal deploy config files for non–GitHub Pages hosts. Cloudflare Pages
    /// has no established single-file pattern here; Workers get a README note only.
    static func files(deployment: DeploymentType, techStack: TechStack) -> [String: String] {
        switch deployment {
        case .vercel:
            return ["vercel.json": vercelJSON(techStack: techStack)]
        case .netlify:
            return ["netlify.toml": netlifyToml(techStack: techStack)]
        case .render:
            return ["render.yaml": renderYAML(techStack: techStack)]
        case .githubPages, .cloudflarePages, .cloudflareWorkers, .railway, .awsAmplify, .sshFtp:
            return [:]
        }
    }

    static func workersReadme(siteName: String) -> String {
        """
        # \(siteName)

        ## Cloudflare Workers

        This repo was created for Cloudflare Workers deployment. Add your Worker
        script and `wrangler.toml`, then connect your Cloudflare account and deploy
        hook in Website Commander → Deploy Integrations.
        """
    }

    private static func vercelJSON(techStack: TechStack) -> String {
        let settings = buildSettings(for: techStack)
        if let command = settings.command {
            return """
            {
              "buildCommand": "\(command)",
              "outputDirectory": "\(settings.publish)"
            }
            """
        }
        return "{}\n"
    }

    private static func netlifyToml(techStack: TechStack) -> String {
        let settings = buildSettings(for: techStack)
        if let command = settings.command {
            return """
            [build]
              command = "\(command)"
              publish = "\(settings.publish)"
            """
        }
        return """
        [build]
          publish = "."
        """
    }

    private static func renderYAML(techStack: TechStack) -> String {
        let settings = buildSettings(for: techStack)
        if let command = settings.command {
            return """
            services:
              - type: web
                name: web
                runtime: static
                buildCommand: \(command)
                staticPublishPath: ./\(settings.publish)
            """
        }
        return """
        services:
          - type: web
            name: web
            runtime: static
            staticPublishPath: .
        """
    }

    static func buildSettings(for techStack: TechStack) -> (command: String?, publish: String) {
        switch techStack {
        case .astro, .eleventy, .custom: return ("npm run build", "dist")
        case .nextjs: return ("npm run build", "out")
        case .sveltekit: return ("npm run build", "build")
        case .hugo: return ("hugo", "public")
        case .jekyll: return ("bundle exec jekyll build", "_site")
        case .vanillaHTML: return (nil, ".")
        }
    }
}

// MARK: - Shared head (SEO-ready)

private func head(_ title: String, _ description: String) -> String {
    """
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>\(title)</title>
    <meta name="description" content="\(description)">
    <meta property="og:title" content="\(title)">
    <meta property="og:description" content="\(description)">
    <meta property="og:type" content="website">
    <meta name="theme-color" content="#6366f1">
    """
}

private let baseCSS = """
:root{--bg:#ffffff;--fg:#0b0b0f;--muted:#5b5b6b;--card:#f5f5f8;--line:#e5e5ee;--accent:#6366f1}
@media(prefers-color-scheme:dark){:root{--bg:#0b0b0f;--fg:#f3f3f7;--muted:#a0a0b0;--card:#16161c;--line:#26262e;--accent:#818cf8}}
*{box-sizing:border-box}
body{margin:0;font:16px/1.6 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:var(--fg);background:var(--bg);-webkit-font-smoothing:antialiased}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
.wrap{max-width:840px;margin:0 auto;padding:0 24px}
h1,h2,h3{line-height:1.2;letter-spacing:-.02em}
.muted{color:var(--muted)}
footer{border-top:1px solid var(--line);margin-top:72px;padding:32px 0;color:var(--muted);font-size:14px}
"""

// MARK: - Templates

private extension SiteTemplate {

    static let portfolio = SiteTemplate(
        id: "portfolio", name: "Portfolio", tagline: "Show your work and projects",
        icon: "person.crop.square.fill", techStack: .vanillaHTML,
        rawFiles: ["index.html": """
        <!doctype html>
        <html lang="en">
        <head>
        \(head("{{SITE_NAME}}", "Portfolio of {{SITE_NAME}} — selected work and projects."))
        <style>
        \(baseCSS)
        header{padding:96px 0 48px}
        header h1{font-size:clamp(2.2rem,6vw,3.4rem);margin:0 0 12px}
        .lead{font-size:1.2rem;max-width:38ch}
        .grid{display:grid;gap:20px;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));margin:40px 0}
        .card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:22px}
        .card h3{margin:0 0 6px}
        .tag{display:inline-block;font-size:12px;color:var(--accent);background:color-mix(in srgb,var(--accent) 14%,transparent);padding:3px 10px;border-radius:999px;margin-top:12px}
        </style>
        </head>
        <body>
        <div class="wrap">
          <header>
            <h1>{{SITE_NAME}}</h1>
            <p class="lead muted">Designer & developer. I build thoughtful, fast products for the web.</p>
          </header>
          <main>
            <h2>Selected work</h2>
            <div class="grid">
              <article class="card"><h3>Project One</h3><p class="muted">A short description of what you made and the impact it had.</p><span class="tag">Web</span></article>
              <article class="card"><h3>Project Two</h3><p class="muted">A short description of what you made and the impact it had.</p><span class="tag">Mobile</span></article>
              <article class="card"><h3>Project Three</h3><p class="muted">A short description of what you made and the impact it had.</p><span class="tag">Brand</span></article>
            </div>
            <h2>About</h2>
            <p class="muted">A paragraph or two about who you are, what you care about, and how to reach you. <a href="mailto:hello@example.com">Get in touch →</a></p>
          </main>
          <footer>© {{SITE_NAME}} · Built with Website Commander</footer>
        </div>
        </body>
        </html>
        """]
    )

    static let landing = SiteTemplate(
        id: "landing", name: "Landing", tagline: "Launch a product or app",
        icon: "sparkles", techStack: .vanillaHTML,
        rawFiles: ["index.html": """
        <!doctype html>
        <html lang="en">
        <head>
        \(head("{{SITE_NAME}}", "{{SITE_NAME}} — the simplest way to get started."))
        <style>
        \(baseCSS)
        .hero{text-align:center;padding:120px 0 64px}
        .hero h1{font-size:clamp(2.4rem,7vw,4rem);margin:0 0 16px}
        .hero p{font-size:1.25rem;max-width:46ch;margin:0 auto 28px}
        .btn{display:inline-block;background:var(--accent);color:#fff;padding:14px 26px;border-radius:12px;font-weight:600}
        .btn:hover{text-decoration:none;opacity:.92}
        .features{display:grid;gap:24px;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));margin:64px 0}
        .feature h3{margin:0 0 6px}
        .dot{width:36px;height:36px;border-radius:10px;background:color-mix(in srgb,var(--accent) 18%,transparent);display:flex;align-items:center;justify-content:center;color:var(--accent);font-weight:700;margin-bottom:12px}
        </style>
        </head>
        <body>
        <div class="wrap">
          <section class="hero">
            <h1>{{SITE_NAME}}</h1>
            <p class="muted">A clear, one-sentence promise about what your product does and who it's for.</p>
            <a class="btn" href="#get-started">Get started</a>
          </section>
          <section class="features">
            <div class="feature"><div class="dot">1</div><h3>Fast</h3><p class="muted">Explain a key benefit in a sentence.</p></div>
            <div class="feature"><div class="dot">2</div><h3>Simple</h3><p class="muted">Explain a key benefit in a sentence.</p></div>
            <div class="feature"><div class="dot">3</div><h3>Reliable</h3><p class="muted">Explain a key benefit in a sentence.</p></div>
          </section>
          <footer id="get-started">© {{SITE_NAME}} · Built with Website Commander</footer>
        </div>
        </body>
        </html>
        """]
    )

    static let blog = SiteTemplate(
        id: "blog", name: "Blog", tagline: "Write posts and updates",
        icon: "text.alignleft", techStack: .vanillaHTML,
        rawFiles: ["index.html": """
        <!doctype html>
        <html lang="en">
        <head>
        \(head("{{SITE_NAME}}", "Writing and updates from {{SITE_NAME}}."))
        <style>
        \(baseCSS)
        header{padding:72px 0 16px}
        header h1{font-size:clamp(2rem,5vw,2.8rem);margin:0}
        .post{padding:28px 0;border-bottom:1px solid var(--line)}
        .post h2{margin:0 0 6px;font-size:1.4rem}
        .date{font-size:13px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}
        </style>
        </head>
        <body>
        <div class="wrap">
          <header>
            <h1>{{SITE_NAME}}</h1>
            <p class="muted">Thoughts, notes, and updates.</p>
          </header>
          <main>
            <article class="post"><div class="date">Jan 1, 2026</div><h2><a href="#">Your first post title</a></h2><p class="muted">A one-line summary or the opening sentence of the post to draw readers in.</p></article>
            <article class="post"><div class="date">Dec 20, 2025</div><h2><a href="#">Another post</a></h2><p class="muted">A one-line summary or the opening sentence of the post to draw readers in.</p></article>
            <article class="post"><div class="date">Dec 5, 2025</div><h2><a href="#">Hello, world</a></h2><p class="muted">A one-line summary or the opening sentence of the post to draw readers in.</p></article>
          </main>
          <footer>© {{SITE_NAME}} · Built with Website Commander</footer>
        </div>
        </body>
        </html>
        """]
    )

    static let docs = SiteTemplate(
        id: "docs", name: "Docs", tagline: "Document a project or API",
        icon: "book.closed.fill", techStack: .vanillaHTML,
        rawFiles: ["index.html": """
        <!doctype html>
        <html lang="en">
        <head>
        \(head("{{SITE_NAME}} Docs", "Documentation for {{SITE_NAME}}."))
        <style>
        \(baseCSS)
        .layout{display:grid;grid-template-columns:220px 1fr;gap:40px;padding-top:48px}
        nav a{display:block;padding:6px 0;color:var(--muted)}
        nav a.active{color:var(--fg);font-weight:600}
        nav h4{text-transform:uppercase;font-size:12px;letter-spacing:.06em;color:var(--muted);margin:20px 0 8px}
        code{background:var(--card);border:1px solid var(--line);border-radius:6px;padding:2px 6px;font-size:.9em}
        pre{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;overflow:auto}
        @media(max-width:720px){.layout{grid-template-columns:1fr}}
        </style>
        </head>
        <body>
        <div class="wrap">
          <div class="layout">
            <nav>
              <h4>Getting started</h4>
              <a class="active" href="#intro">Introduction</a>
              <a href="#install">Installation</a>
              <h4>Guides</h4>
              <a href="#usage">Usage</a>
              <a href="#api">API reference</a>
            </nav>
            <main>
              <h1 id="intro">{{SITE_NAME}} Docs</h1>
              <p class="muted">Welcome to the documentation. Describe what this project does and who it's for.</p>
              <h2 id="install">Installation</h2>
              <pre><code>npm install your-package</code></pre>
              <h2 id="usage">Usage</h2>
              <p class="muted">Show a minimal example of how to use it. Inline <code>code</code> works too.</p>
              <footer>© {{SITE_NAME}} · Built with Website Commander</footer>
            </main>
          </div>
        </div>
        </body>
        </html>
        """]
    )

    static let astroMinimal = SiteTemplate(
        id: "astro", name: "Astro", tagline: "Minimal static site with Astro",
        icon: "sparkles", techStack: .astro,
        rawFiles: [
            "package.json": """
            {
              "name": "{{SITE_NAME_SLUG}}",
              "type": "module",
              "private": true,
              "version": "0.0.1",
              "scripts": {
                "dev": "astro dev",
                "build": "astro build",
                "preview": "astro preview"
              },
              "dependencies": {
                "astro": "^4.0.0"
              }
            }
            """,
            "astro.config.mjs": """
            import { defineConfig } from 'astro/config';

            export default defineConfig({});
            """,
            "src/pages/index.astro": """
            ---
            const title = "{{SITE_NAME}}";
            ---
            <html lang="en">
              <head>
                <meta charset="utf-8" />
                <meta name="viewport" content="width=device-width, initial-scale=1" />
                <title>{title}</title>
              </head>
              <body>
                <main>
                  <h1>{title}</h1>
                  <p>Welcome to your new Astro site.</p>
                </main>
              </body>
            </html>
            """
        ]
    )

    static let nextStatic = SiteTemplate(
        id: "next-static", name: "Next.js (static)", tagline: "Static export starter",
        icon: "app.window.reference", techStack: .nextjs,
        rawFiles: [
            "package.json": """
            {
              "name": "{{SITE_NAME_SLUG}}",
              "private": true,
              "scripts": {
                "dev": "next dev",
                "build": "next build",
                "start": "next start"
              },
              "dependencies": {
                "next": "^14.0.0",
                "react": "^18.0.0",
                "react-dom": "^18.0.0"
              }
            }
            """,
            "next.config.js": """
            /** @type {import('next').NextConfig} */
            const nextConfig = { output: 'export' };
            module.exports = nextConfig;
            """,
            "pages/index.js": """
            export default function Home() {
              return (
                <main>
                  <h1>{{SITE_NAME}}</h1>
                  <p>Welcome to your new Next.js site.</p>
                </main>
              );
            }
            """
        ]
    )
}
