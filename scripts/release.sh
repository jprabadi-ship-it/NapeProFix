#!/bin/zsh
set -euo pipefail

# Builds a notarized NapeProFix.dmg.
#
# Requires a Developer ID Application certificate in the keychain, plus one of
# two ways to authenticate with the notary service:
#
#   1. A notarytool keychain profile (one-time setup):
#        xcrun notarytool store-credentials NapeProFix \
#          --apple-id <apple-id> --team-id <team-id>
#      Both storing and reading it need access to the login keychain, so run
#      those from a normal Terminal window. A shell without a GUI session gets
#      "User interaction is not allowed."
#
#   2. An App Store Connect API key, which needs no keychain at all and is the
#      better option for anything scripted. Set:
#        NAPEPROFIX_API_KEY    path to the AuthKey_XXXXXXXX.p8 file
#        NAPEPROFIX_API_KEY_ID the key ID (the XXXXXXXX part)
#        NAPEPROFIX_API_ISSUER the issuer UUID from App Store Connect
#      Keep the .p8 outside the repository and outside any synced folder.
#
# --skip-notarize stops after the disk image, for a quick local build.

project_dir="${0:A:h:h}"
volume_name="NapeProFix"
notary_profile="${NAPEPROFIX_NOTARY_PROFILE:-NapeProFix}"

plist="$project_dir/Resources/Info.plist"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")

# Google Drive re-adds extended attributes the moment they are cleared, which
# breaks codesign, so stage everything on a local disk.
stage_dir="/tmp/napeprofix-dmg"
dmg_path="$project_dir/build/$volume_name-$version.dmg"

skip_notarize=false
[[ "${1:-}" == "--skip-notarize" ]] && skip_notarize=true

# build-app.sh prefers Developer ID and applies the Hardened Runtime, which
# notarization requires.
"$project_dir/scripts/build-app.sh" >/dev/null
app_dir="/tmp/napeprofix-stage/NapeProFix.app"

# Capture first, then filter. Piping codesign straight into an awk that exits
# early gives codesign a SIGPIPE, and with pipefail that aborts the script —
# silently, right after the signing step.
signing_info=$(codesign -dvv "$app_dir" 2>&1 || true)
identity=$(printf '%s\n' "$signing_info" | awk -F'Authority=' '/Authority=Developer ID/ {print $2; exit}')
if [[ -z "$identity" ]]; then
  echo "エラー: Developer ID で署名されていません。公証には Developer ID Application 証明書が必要です。" >&2
  exit 1
fi
echo "署名ID: $identity" >&2

rm -rf "$stage_dir"
mkdir -p "$stage_dir" "$project_dir/build"
cp -R "$app_dir" "$stage_dir/"
ln -s /Applications "$stage_dir/Applications"

rm -f "$dmg_path"
hdiutil create -volname "$volume_name" -srcfolder "$stage_dir" \
  -ov -format UDZO "$dmg_path" >/dev/null
codesign --force --timestamp --sign "$identity" "$dmg_path"

if [[ "$skip_notarize" == true ]]; then
  echo "$dmg_path"
  exit 0
fi

if [[ -n "${NAPEPROFIX_API_KEY:-}" ]]; then
  auth=(--key "$NAPEPROFIX_API_KEY"
        --key-id "$NAPEPROFIX_API_KEY_ID"
        --issuer "$NAPEPROFIX_API_ISSUER")
else
  auth=(--keychain-profile "$notary_profile")
fi

xcrun notarytool submit "$dmg_path" "${auth[@]}" --wait
# Stapling attaches the ticket to the disk image, so it opens even offline.
xcrun stapler staple "$dmg_path"
# The real check: this is what Gatekeeper will say on someone else's Mac.
spctl --assess --type open --context context:primary-signature -v "$dmg_path"

echo "$dmg_path"
