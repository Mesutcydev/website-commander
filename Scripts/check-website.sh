#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SITE_DIR="${ROOT_DIR}/website"

python3 - "$SITE_DIR" <<'PY'
from html.parser import HTMLParser
from pathlib import Path
import sys

site = Path(sys.argv[1])
required = [
    site / "index.html",
    site / "privacy.html",
    site / "404.html",
    site / "robots.txt",
    site / ".nojekyll",
    site / "css/tokens.css",
    site / "css/base.css",
    site / "css/components.css",
    site / "css/responsive.css",
    site / "js/site.js",
    site / "assets/app-icon.png",
]
missing = [str(path.relative_to(site)) for path in required if not path.exists()]
if missing:
    raise SystemExit("Missing website files: " + ", ".join(missing))

class PageParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.title = ""
        self.description = ""
        self.h1 = 0
        self.images = []
        self.links = []
        self.in_title = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "title":
            self.in_title = True
        elif tag == "meta" and attrs.get("name") == "description":
            self.description = attrs.get("content", "")
        elif tag == "h1":
            self.h1 += 1
        elif tag == "img":
            self.images.append((attrs.get("src", ""), attrs.get("alt")))
        elif tag == "a":
            self.links.append(attrs.get("href", ""))

    def handle_endtag(self, tag):
        if tag == "title":
            self.in_title = False

    def handle_data(self, data):
        if self.in_title:
            self.title += data

errors = []
for page in (site / "index.html", site / "privacy.html", site / "404.html"):
    parser = PageParser()
    parser.feed(page.read_text(encoding="utf-8"))
    relative = page.relative_to(site)
    if not parser.title.strip():
        errors.append(f"{relative}: missing title")
    if not parser.description.strip():
        errors.append(f"{relative}: missing meta description")
    if relative.name != "404.html" and parser.h1 != 1:
        errors.append(f"{relative}: expected exactly one h1, found {parser.h1}")
    for src, alt in parser.images:
        if not src:
            errors.append(f"{relative}: image is missing src")
        if alt is None:
            errors.append(f"{relative}: image {src!r} is missing alt")
        if src and not src.startswith(("http://", "https://", "data:", "#")):
            target = (page.parent / src).resolve()
            if not target.is_file():
                errors.append(f"{relative}: missing image {src}")
    for href in parser.links:
        if not href or href.startswith(("#", "mailto:", "tel:", "http://", "https://")):
            continue
        target = (page.parent / href.split("#", 1)[0]).resolve()
        if target.is_dir():
            target = target / "index.html"
        if not target.is_file():
            errors.append(f"{relative}: missing local link {href}")

public_text = "\n".join(
    path.read_text(encoding="utf-8")
    for path in (site / "index.html", site / "privacy.html", site / "404.html")
)
if "SiteAgent" in public_text:
    errors.append("public website still contains the legacy SiteAgent brand")
for token in ("<owner>", "<custom-domain>", "YOUR_", "TODO"):
    if token in public_text:
        errors.append(f"public website contains placeholder {token}")

if errors:
    print("Website check failed:")
    for error in errors:
        print(f"- {error}")
    raise SystemExit(1)

print("Website check passed: pages, metadata, images, links, and public branding are valid.")
PY
