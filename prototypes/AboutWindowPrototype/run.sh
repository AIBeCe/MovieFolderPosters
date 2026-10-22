#!/bin/bash
set -euo pipefail

prototype_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="$prototype_dir/build"
app_bundle="$build_dir/AboutWindowPrototype-Review.app"
executable_dir="$app_bundle/Contents/MacOS"
resources_dir="$app_bundle/Contents/Resources"

mkdir -p "$executable_dir" "$resources_dir/Assets"
swiftc -parse-as-library -module-cache-path "$build_dir/ModuleCache" \
  "$prototype_dir/main.swift" \
  -o "$executable_dir/AboutWindowPrototype"
cp "$prototype_dir/Assets/"* "$resources_dir/Assets/"

cat > "$app_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleExecutable</key>
  <string>AboutWindowPrototype</string>
  <key>CFBundleIdentifier</key>
  <string>local.moviefolderposters.about-prototype.v3</string>
  <key>CFBundleName</key>
  <string>About Window Prototype</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$app_bundle/Contents/PkgInfo"

echo "Built: $app_bundle"
echo "Open the app bundle in Finder to launch the prototype."
