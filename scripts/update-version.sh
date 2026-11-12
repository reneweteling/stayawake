#!/usr/bin/env bash
# update-version.sh: sets CFBundleShortVersionString in Info.plist.
# Portable: works on macOS (PlistBuddy) and Linux (sed fallback).
# Usage: ./scripts/update-version.sh 1.2.3
set -euo pipefail

VERSION="${1:?Usage: $0 <version>}"
PLIST="Sources/StayAwake/Resources/Info.plist"

if [[ -x /usr/libexec/PlistBuddy ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${PLIST}"
else
    # Linux: sed the line immediately following <key>CFBundleShortVersionString</key>.
    # Info.plist is UTF-8 XML with two-space indent; we swap the <string>…</string>
    # that directly follows the key.
    tmp="$(mktemp)"
    awk -v v="${VERSION}" '
        /<key>CFBundleShortVersionString<\/key>/ { print; getline; sub(/<string>[^<]*<\/string>/, "<string>" v "</string>"); print; next }
        { print }
    ' "${PLIST}" > "${tmp}"
    mv "${tmp}" "${PLIST}"
fi

echo "Set CFBundleShortVersionString to ${VERSION} in ${PLIST}"
