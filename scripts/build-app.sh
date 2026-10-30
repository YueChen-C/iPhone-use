#!/bin/zsh
# Builds a signed iPhoneUse.app for distribution or launch-item use. For development,
# `swift run -c release iphone-use` can run the executable without creating an app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
BUILD_ARCH="${BUILD_ARCH:-native}"
case "$CONFIG" in
  debug|release) ;;
  *) print -u2 -- "CONFIG must be debug or release."; exit 1 ;;
esac
case "$BUILD_ARCH" in
  native|arm64|x86_64) architectures=("$BUILD_ARCH") ;;
  universal) architectures=(arm64 x86_64) ;;
  *) print -u2 -- "BUILD_ARCH must be native, arm64, x86_64, or universal."; exit 1 ;;
esac
if [[ -n "${APP_VERSION:-}" && ! "$APP_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 -- "APP_VERSION must be a numeric version such as 0.2.0."
  exit 1
fi
if [[ -n "${APP_BUILD:-}" && ! "$APP_BUILD" =~ '^[1-9][0-9]*$' ]]; then
  print -u2 -- "APP_BUILD must be a positive integer."
  exit 1
fi

binary_paths=()
for architecture in "${architectures[@]}"; do
  build_args=(-c "$CONFIG")
  [[ "$architecture" == native ]] || build_args+=(--arch "$architecture")
  swift build "${build_args[@]}"
  bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"
  binary_paths+=("$bin_dir/iphone-use")
done

APP="build/iPhoneUse.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if (( ${#binary_paths[@]} == 1 )); then
  cp "${binary_paths[1]}" "$APP/Contents/MacOS/iphone-use"
else
  # Build each architecture with SwiftPM's native backend, then merge before signing.
  lipo -create "${binary_paths[@]}" -output "$APP/Contents/MacOS/iphone-use"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Sources/iPhoneUse/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp LICENSE "$APP/Contents/Resources/LICENSE"
if [[ -n "${APP_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${APP_BUILD:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$APP/Contents/Info.plist"
fi

sign() { codesign --force --options runtime --entitlements Resources/iPhoneUse.entitlements --sign "$1" "$APP"; }
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  # Explicit release identities must succeed; never silently downgrade their signature.
  IDENTITY="$CODESIGN_IDENTITY"
  sign "$IDENTITY"
else
  IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
  IDENTITY="${IDENTITY:--}"
  # Preserve the convenient ad-hoc fallback for ordinary local builds.
  sign "$IDENTITY" 2>/dev/null || { IDENTITY="-"; sign "$IDENTITY"; }
fi
codesign --verify --strict "$APP"
echo "built $APP (signed: $IDENTITY)"
