#!/bin/bash
# Builds a universal (arm64 + x86_64) "X-ray Viewer.app" plus an installer .pkg and a .dmg into ./build.
# Needs only the Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.2.0}"
APP="build/X-ray Viewer.app"
rm -rf build && mkdir -p build/slices "$APP/Contents/MacOS"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos11.0" Sources/*.swift -o "build/slices/$arch"
done
lipo -create build/slices/arm64 build/slices/x86_64 -output "$APP/Contents/MacOS/XrayViewer"
sed "s/<string>1.0<\/string>/<string>$VERSION<\/string>/" Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"   # ad-hoc signature; required for arm64 to launch
rm -rf build/slices
lipo -archs "$APP/Contents/MacOS/XrayViewer"

# --- Installer package (.pkg): installs to /Applications ---
mkdir -p build/pkgroot/Applications
ditto --norsrc --noextattr --noqtn "$APP" "build/pkgroot/Applications/X-ray Viewer.app"
xattr -cr build/pkgroot
pkgbuild --analyze --root build/pkgroot build/components.plist >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" build/components.plist
COPYFILE_DISABLE=1 pkgbuild --root build/pkgroot --component-plist build/components.plist \
  --identifier io.github.xrayviewer --version "$VERSION" --install-location / \
  "build/XrayViewer-$VERSION.pkg" >/dev/null

# --- Disk image (.dmg): drag-and-drop install ---
mkdir -p build/dmgroot
ditto --norsrc --noextattr --noqtn "$APP" "build/dmgroot/X-ray Viewer.app"
xattr -cr build/dmgroot
ln -s /Applications build/dmgroot/Applications
hdiutil create -quiet -volname "X-ray Viewer" -srcfolder build/dmgroot -ov -format UDZO "build/XrayViewer-$VERSION.dmg"

rm -rf build/pkgroot build/dmgroot build/components.plist
ls -lh build | sed 1d
