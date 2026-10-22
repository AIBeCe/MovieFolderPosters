#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/release/package.sh --identity IDENTITY --team-id TEAM_ID \
  --notary-profile PROFILE --output-dir DIRECTORY

Builds, signs, notarizes, staples, and assesses a Developer ID DMG. The
notary profile must already exist in the user's Keychain.
USAGE
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

identity=
team_id=
notary_profile=
output_dir=

while (($#)); do
  case "$1" in
    --identity)
      (($# >= 2)) || fail "--identity requires a value"
      identity=$2
      shift 2
      ;;
    --team-id)
      (($# >= 2)) || fail "--team-id requires a value"
      team_id=$2
      shift 2
      ;;
    --notary-profile)
      (($# >= 2)) || fail "--notary-profile requires a value"
      notary_profile=$2
      shift 2
      ;;
    --output-dir)
      (($# >= 2)) || fail "--output-dir requires a value"
      output_dir=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "$identity" ]] || fail "--identity is required"
[[ -n "$team_id" ]] || fail "--team-id is required"
[[ -n "$notary_profile" ]] || fail "--notary-profile is required"
[[ -n "$output_dir" ]] || fail "--output-dir is required"
[[ "$identity" == Developer\ ID\ Application:* ]] || fail "identity must be a Developer ID Application identity"
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || fail "team ID must contain 10 uppercase letters or digits"

command -v xcodebuild >/dev/null || fail "xcodebuild is unavailable"
command -v xcrun >/dev/null || fail "xcrun is unavailable"
command -v codesign >/dev/null || fail "codesign is unavailable"
command -v hdiutil >/dev/null || fail "hdiutil is unavailable"
command -v spctl >/dev/null || fail "spctl is unavailable"
[[ -d MovieFolderPosters/MovieFolderPosters.xcodeproj ]] || fail "run this script from the repository root"
[[ -f scripts/release/ExportOptions.plist ]] || fail "ExportOptions.plist is missing"
[[ ! -e "$output_dir" ]] || fail "output directory already exists: $output_dir"

mkdir -p "$(dirname "$output_dir")"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/movie-folder-posters-release.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

archive_path="$work_dir/MovieFolderPosters.xcarchive"
export_path="$work_dir/export"
export_options="$work_dir/ExportOptions.plist"
cp scripts/release/ExportOptions.plist "$export_options"
plutil -replace signingCertificate -string "$identity" "$export_options"
plutil -replace teamID -string "$team_id" "$export_options"

xcodebuild archive \
  -project MovieFolderPosters/MovieFolderPosters.xcodeproj \
  -scheme MovieFolderPosters \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive_path" \
  -derivedDataPath "$work_dir/DerivedData" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$identity" \
  DEVELOPMENT_TEAM="$team_id" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES

xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$export_options"

app_path="$export_path/MovieFolderPosters.app"
[[ -d "$app_path" ]] || fail "export did not produce MovieFolderPosters.app"
codesign --verify --deep --strict --verbose=2 "$app_path"
codesign -dv --verbose=4 "$app_path" 2>&1 | grep -F "Authority=$identity" >/dev/null \
  || fail "exported app is not signed with the requested identity"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
[[ -n "$version" ]] || fail "app version is missing"

mkdir -p "$output_dir"
dmg_path="$output_dir/MovieFolderPosters-${version}-macOS.dmg"
hdiutil create -volname 'Movie Folder Posters' -srcfolder "$app_path" \
  -ov -format UDZO "$dmg_path"
codesign --force --sign "$identity" --timestamp "$dmg_path"
codesign --verify --verbose=2 "$dmg_path"

xcrun notarytool submit "$dmg_path" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$dmg_path"
xcrun stapler validate "$dmg_path"
spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"

printf 'Release DMG ready: %s\n' "$dmg_path"
