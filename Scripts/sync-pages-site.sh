#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./Scripts/sync-pages-site.sh --source website --destination /path/to/pages-repo

Copies the canonical static site into an existing git repository without committing
or pushing. A destination CNAME and common verification files are preserved.
EOF
}

SOURCE=""
DESTINATION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE="${2:-}"; shift 2 ;;
    --destination) DESTINATION="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$SOURCE" || -z "$DESTINATION" ]]; then
  usage >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$(cd "$ROOT_DIR/$SOURCE" 2>/dev/null && pwd)"
DEST_DIR="$(cd "$DESTINATION" 2>/dev/null && pwd)"

if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "Source directory does not exist: $SOURCE_DIR" >&2
  exit 1
fi
if [[ ! -d "$DEST_DIR/.git" && ! -f "$DEST_DIR/.git" ]]; then
  echo "Destination is not a git repository: $DEST_DIR" >&2
  exit 1
fi
if ! command -v rsync >/dev/null 2>&1; then
  echo "rsync is required." >&2
  exit 1
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/website-commander-pages.XXXXXX")"
cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

for preserved in CNAME .nojekyll google*.html BingSiteAuth.xml; do
  while IFS= read -r -d '' file; do
    relative="${file#"$DEST_DIR/"}"
    mkdir -p "$TEMP_DIR/$(dirname "$relative")"
    cp "$file" "$TEMP_DIR/$relative"
  done < <(find "$DEST_DIR" -maxdepth 2 -type f -name "$preserved" -print0 2>/dev/null)
done

mkdir -p "$DEST_DIR"
echo "Syncing $SOURCE_DIR/ into $DEST_DIR/"
rsync -a --delete --itemize-changes "$SOURCE_DIR/" "$DEST_DIR/"

while IFS= read -r -d '' file; do
  relative="${file#"$TEMP_DIR/"}"
  mkdir -p "$DEST_DIR/$(dirname "$relative")"
  cp "$file" "$DEST_DIR/$relative"
  echo "preserved $relative"
done < <(find "$TEMP_DIR" -type f -print0)

echo
echo "Sync complete. No commit or push was performed."
echo "Review: git -C \"$DEST_DIR\" status --short"
