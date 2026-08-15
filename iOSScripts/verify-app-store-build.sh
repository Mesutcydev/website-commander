#!/bin/bash
set -e

# verify-app-store-build.sh
# Verifies that an AppStore/production build does NOT contain PCC symbols, flags, or entitlements.

echo "========================================="
echo "SiteAgent AppStore Build Verification"
echo "========================================="

# 1. Check configuration environment variables
if [ -n "$SWIFT_ACTIVE_COMPILATION_CONDITIONS" ]; then
    echo "Checking SWIFT_ACTIVE_COMPILATION_CONDITIONS: $SWIFT_ACTIVE_COMPILATION_CONDITIONS"
    if [[ "$SWIFT_ACTIVE_COMPILATION_CONDITIONS" =~ "IOS27_PCC_EXPERIMENTAL" ]]; then
        echo "❌ ERROR: IOS27_PCC_EXPERIMENTAL is defined in active compilation conditions!"
        exit 1
    fi
fi

# 2. Scan the real leakage vectors — the xcconfig files wired to AppStore/Release
#    (plus the shared Base.xcconfig they #include) and project.yml — for any
#    forbidden PCC / private-cloud-compute symbols. PCC-only configs
#    (Debug-PCC, PCC-TestFlight) legitimately carry these and are excluded.
echo "Verifying Configuration xcconfig files for PCC leakage..."
FORBIDDEN_PATTERN='private-cloud-compute|PrivateCloudCompute|IOS27_PCC_EXPERIMENTAL|PCC_TESTFLIGHT_BUILD|APPLE_FM|PCC\.entitlements'
if command -v rg >/dev/null 2>&1; then
    # ripgrep uses Rust regular expressions by default. Its `-E` flag selects
    # a text encoding (unlike grep's extended-regex flag), so `rg -nE` can
    # silently turn this safety check into an invalid command and false pass.
    GREP=(rg -n)
else
    GREP=(grep -nE)
fi
for f in Configuration/AppStore.xcconfig Configuration/Release.xcconfig Configuration/Base.xcconfig; do
    if [ -f "$f" ] && "${GREP[@]}" "$FORBIDDEN_PATTERN" "$f" >/dev/null 2>&1; then
        echo "❌ ERROR: Forbidden PCC symbol detected in $f:"
        "${GREP[@]}" "$FORBIDDEN_PATTERN" "$f" || true
        exit 1
    fi
done
if [ -f "project.yml" ] && "${GREP[@]}" 'private-cloud-compute|PrivateCloudCompute' project.yml >/dev/null 2>&1; then
    echo "❌ ERROR: Forbidden PCC symbol detected in project.yml:"
    "${GREP[@]}" 'private-cloud-compute|PrivateCloudCompute' project.yml || true
    exit 1
fi
echo "✓ xcconfig/project.yml clean: no PCC leakage in AppStore/Release/Base."

# 3. Check entitlements of the built app if a path is passed
if [ -n "$1" ]; then
    APP_PATH="$1"
    echo "Analyzing built app bundle: $APP_PATH"
    
    if [ ! -d "$APP_PATH" ]; then
        echo "❌ ERROR: Provided path does not exist or is not a directory: $APP_PATH"
        exit 1
    fi
    
    # Locate executable
    EXE_NAME=$(plutil -extract CFBundleExecutable raw "$APP_PATH/Info.plist" || echo "SiteAgent")
    EXE_PATH="$APP_PATH/$EXE_NAME"
    
    if [ ! -f "$EXE_PATH" ]; then
        echo "❌ ERROR: Executable not found at $EXE_PATH"
        exit 1
    fi
    
    # Verify deployment target is iOS 17.0
    MIN_OS=$(plutil -extract MinimumOSVersion raw "$APP_PATH/Info.plist" || echo "")
    echo "Minimum OS Target: $MIN_OS"
    if [ "$MIN_OS" != "17.0" ]; then
        echo "❌ ERROR: Minimum deployment target was raised to $MIN_OS (expected 17.0)!"
        exit 1
    fi
    
    # Check entitlements using codesign
    echo "Verifying entitlements..."
    ENTITLEMENTS=$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || echo "")
    if echo "$ENTITLEMENTS" | grep -q "com.apple.developer.private-cloud-compute"; then
        echo "❌ ERROR: Signed bundle contains com.apple.developer.private-cloud-compute entitlement!"
        exit 1
    fi
    echo "✓ Entitlements clean: com.apple.developer.private-cloud-compute is ABSENT."
    
    # Check for compiled PCC references/symbols in binary strings
    echo "Scanning binary for PCC symbols..."
    if strings "$EXE_PATH" | grep -q "PrivateCloudComputeLanguageModel"; then
        echo "❌ ERROR: PrivateCloudComputeLanguageModel reference found in binary strings!"
        exit 1
    fi
    echo "✓ Binary clean: PrivateCloudComputeLanguageModel symbols are ABSENT."
else
    echo "⚠️ WARNING: No app path provided. Skipping codesign and strings checks."
fi

echo "========================================="
echo "✓ AppStore build verification PASSED!"
echo "========================================="
exit 0
