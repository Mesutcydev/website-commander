#!/usr/bin/env bash
# Fails CI/local checks when Package.resolved is missing after the policy change
# that stopped gitignoring it. Run after `xcodebuild -resolvePackageDependencies`.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -f Package.resolved ]]; then
  # Also accept nested paths Xcode sometimes writes
  FOUND="$(find . -name Package.resolved -not -path './.git/*' | head -1 || true)"
  if [[ -z "$FOUND" ]]; then
    echo "❌ Package.resolved is missing."
    echo "   On a Mac with Xcode:"
    echo "     xcodegen generate"
    echo "     xcodebuild -resolvePackageDependencies -project SiteAgent.xcodeproj -scheme SiteAgent"
    echo "     git add Package.resolved && git commit -m 'Pin SPM dependencies'"
    exit 1
  fi
  echo "✓ Found $FOUND"
  exit 0
fi
echo "✓ Package.resolved present"
exit 0
