#!/usr/bin/env bash
# Builds LiteRT-LM XCFrameworks for the flutter_lite_lm iOS plugin.
#
# This script:
#   1. Ensures scriptease/LiteRTLMMinimal is cloned + submodule initialized
#   2. Runs bazel build to produce libc_engine.a for 3 platform slices
#   3. Packages libc_engine.a into LiteRTLM.xcframework (static library)
#   4. Wraps libGemmaModelConstraintProvider.dylib into a proper .framework
#      bundle per slice (required by CocoaPods, which rejects raw .dylib)
#   5. Packages those into GemmaModelConstraintProvider.xcframework (dynamic framework)
#   6. Copies both xcframeworks into flutter_lite_lm/ios/Frameworks/
#
# First-time build takes 30-60 min. Subsequent runs are cached by Bazel.
#
# Usage: scripts/build_ios_frameworks.sh [workdir]
#   workdir defaults to /tmp/LiteRTLMMinimal

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKDIR="${1:-/tmp/LiteRTLMMinimal}"
MINIMAL_REPO="https://github.com/scriptease/LiteRTLMMinimal.git"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

echo "==> Plugin root: $PLUGIN_ROOT"
echo "==> Workdir:     $WORKDIR"

# ---------------------------------------------------------------------------
# 1. Clone + init submodule if needed
# ---------------------------------------------------------------------------
if [ ! -d "$WORKDIR" ]; then
  echo "==> Cloning $MINIMAL_REPO ..."
  git clone --depth 1 "$MINIMAL_REPO" "$WORKDIR"
fi
if [ ! -d "$WORKDIR/LiteRT-LM/c" ]; then
  echo "==> Initializing LiteRT-LM submodule ..."
  (cd "$WORKDIR" && git submodule update --init --depth 1)
fi

# ---------------------------------------------------------------------------
# 2. Build libc_engine.a for all 3 slices via Bazel
# ---------------------------------------------------------------------------
if [ ! -f "$WORKDIR/build/lib/ios_arm64/libc_engine.a" ] || \
   [ ! -f "$WORKDIR/build/lib/ios_sim_arm64/libc_engine.a" ] || \
   [ ! -f "$WORKDIR/build/lib/macos_arm64/libc_engine.a" ]; then
  echo "==> Building libc_engine.a for all platforms (can take 30-60 minutes) ..."
  (cd "$WORKDIR" && bash scripts/build-litert-macos.sh all)
else
  echo "==> libc_engine.a already built for all slices — skipping bazel build."
fi

# ---------------------------------------------------------------------------
# 3. Wrap libc_engine.a into LiteRTLM.framework bundles (static frameworks)
#    CocoaPods rejects naked static libraries inside xcframeworks — it requires
#    a proper framework bundle. We build static frameworks manually.
# ---------------------------------------------------------------------------
echo "==> Wrapping libc_engine.a into LiteRTLM.framework bundles ..."
WRAP_DIR="$WORKDIR/build/wrapped-frameworks"
rm -rf "$WRAP_DIR"
mkdir -p "$WRAP_DIR"

wrap_static_framework() {
  local PLATFORM="$1"      # macos_arm64 | ios_arm64 | ios_sim_arm64
  local PLIST_PLATFORM="$2" # MacOSX | iPhoneOS | iPhoneSimulator
  local MIN_OS="$3"
  local FW_NAME="LiteRTLM"

  local SRC_LIB="$WORKDIR/build/lib/$PLATFORM/libc_engine.a"
  local OUT="$WRAP_DIR/$PLATFORM/$FW_NAME.framework"
  mkdir -p "$OUT/Headers"

  if [ "$PLATFORM" = "macos_arm64" ]; then
    mkdir -p "$OUT/Versions/A/Headers" "$OUT/Versions/A/Resources"
    cp "$SRC_LIB" "$OUT/Versions/A/$FW_NAME"
    cp "$WORKDIR/LiteRT-LM/c/engine.h" "$OUT/Versions/A/Headers/"
    (cd "$OUT" && ln -sf "A" "Versions/Current")
    (cd "$OUT" && ln -sf "Versions/Current/$FW_NAME" "$FW_NAME")
    rm -rf "$OUT/Headers"
    (cd "$OUT" && ln -sf "Versions/Current/Headers" "Headers")
    (cd "$OUT" && ln -sf "Versions/Current/Resources" "Resources")
    local PLIST_DIR="$OUT/Versions/A/Resources"
    local HEADERS_DIR="$OUT/Versions/A/Headers"
  else
    cp "$SRC_LIB" "$OUT/$FW_NAME"
    cp "$WORKDIR/LiteRT-LM/c/engine.h" "$OUT/Headers/"
    local PLIST_DIR="$OUT"
    local HEADERS_DIR="$OUT/Headers"
  fi

  # Modulemap so Swift/ObjC can import LiteRTLM
  cat > "$HEADERS_DIR/module.modulemap" <<MODULEMAP
framework module $FW_NAME {
  umbrella header "engine.h"
  export *
  module * { export * }
}
MODULEMAP

  cat > "$PLIST_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$FW_NAME</string>
  <key>CFBundleIdentifier</key><string>com.google.ai.edge.$FW_NAME</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$FW_NAME</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$PLIST_PLATFORM</string></array>
  <key>MinimumOSVersion</key><string>$MIN_OS</string>
</dict>
</plist>
PLIST
}

wrap_static_framework macos_arm64 MacOSX 11.0
wrap_static_framework ios_arm64 iPhoneOS 13.0
wrap_static_framework ios_sim_arm64 iPhoneSimulator 13.0

# Create LiteRTLM.xcframework using the wrapped static frameworks
OUT_XCF="$WORKDIR/build/xcframeworks/LiteRTLM.xcframework"
rm -rf "$OUT_XCF"
mkdir -p "$WORKDIR/build/xcframeworks"

echo "==> Creating LiteRTLM.xcframework from wrapped static frameworks ..."
xcodebuild -create-xcframework \
  -framework "$WRAP_DIR/ios_arm64/LiteRTLM.framework" \
  -framework "$WRAP_DIR/ios_sim_arm64/LiteRTLM.framework" \
  -framework "$WRAP_DIR/macos_arm64/LiteRTLM.framework" \
  -output "$OUT_XCF"

echo "    $(du -sh "$OUT_XCF" | awk '{print $1}') → $OUT_XCF"

# ---------------------------------------------------------------------------
# 4. Wrap libGemmaModelConstraintProvider.dylib as a proper .framework bundle
#    CocoaPods rejects raw .dylib inside an xcframework — it demands a real
#    framework directory with Info.plist and a binary named after the framework.
# ---------------------------------------------------------------------------
echo "==> Wrapping libGemmaModelConstraintProvider.dylib into .framework bundles ..."
FW_NAME="GemmaModelConstraintProvider"
# WRAP_DIR already created in step 3 for LiteRTLM — we reuse it.

wrap_slice() {
  local PLATFORM="$1"      # macos_arm64 | ios_arm64 | ios_sim_arm64
  local PLIST_PLATFORM="$2" # MacOSX | iPhoneOS | iPhoneSimulator
  local MIN_OS="$3"

  local SRC_DYLIB="$WORKDIR/build/lib/$PLATFORM/libGemmaModelConstraintProvider.dylib"
  local OUT="$WRAP_DIR/$PLATFORM/$FW_NAME.framework"
  mkdir -p "$OUT"

  if [ "$PLATFORM" = "macos_arm64" ]; then
    # macOS frameworks use Versions/A/
    mkdir -p "$OUT/Versions/A/Headers" "$OUT/Versions/A/Resources"
    cp "$SRC_DYLIB" "$OUT/Versions/A/$FW_NAME"
    (cd "$OUT" && ln -sf "A" "Versions/Current")
    (cd "$OUT" && ln -sf "Versions/Current/$FW_NAME" "$FW_NAME")
    (cd "$OUT" && ln -sf "Versions/Current/Headers" "Headers")
    (cd "$OUT" && ln -sf "Versions/Current/Resources" "Resources")
    local PLIST_DIR="$OUT/Versions/A/Resources"
  else
    # iOS frameworks are flat
    cp "$SRC_DYLIB" "$OUT/$FW_NAME"
    local PLIST_DIR="$OUT"
  fi

  # Fix install name so dyld finds it at @rpath/GemmaModelConstraintProvider.framework/GemmaModelConstraintProvider
  install_name_tool -id \
    "@rpath/$FW_NAME.framework/$FW_NAME" \
    "$(find "$OUT" -name "$FW_NAME" -type f | head -1)" 2>/dev/null || true

  # Minimal Info.plist
  cat > "$PLIST_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$FW_NAME</string>
  <key>CFBundleIdentifier</key><string>com.google.ai.edge.$FW_NAME</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$FW_NAME</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$PLIST_PLATFORM</string></array>
  <key>MinimumOSVersion</key><string>$MIN_OS</string>
</dict>
</plist>
PLIST
}

wrap_slice macos_arm64 MacOSX 11.0
wrap_slice ios_arm64 iPhoneOS 13.0
wrap_slice ios_sim_arm64 iPhoneSimulator 13.0

# ---------------------------------------------------------------------------
# 5. Create GemmaModelConstraintProvider.xcframework using the wrapped frameworks
# ---------------------------------------------------------------------------
OUT_XCF="$WORKDIR/build/xcframeworks/$FW_NAME.xcframework"
rm -rf "$OUT_XCF"

echo "==> Creating $FW_NAME.xcframework from wrapped frameworks ..."
xcodebuild -create-xcframework \
  -framework "$WRAP_DIR/ios_arm64/$FW_NAME.framework" \
  -framework "$WRAP_DIR/ios_sim_arm64/$FW_NAME.framework" \
  -framework "$WRAP_DIR/macos_arm64/$FW_NAME.framework" \
  -output "$OUT_XCF"

echo "    $(du -sh "$OUT_XCF" | awk '{print $1}') → $OUT_XCF"

# ---------------------------------------------------------------------------
# 6. Copy both xcframeworks into the plugin
# ---------------------------------------------------------------------------
DEST="$PLUGIN_ROOT/ios/Frameworks"
mkdir -p "$DEST"
rm -rf "$DEST/LiteRTLM.xcframework" "$DEST/$FW_NAME.xcframework"
echo "==> Copying xcframeworks into $DEST ..."
cp -R "$WORKDIR/build/xcframeworks/LiteRTLM.xcframework" "$DEST/"
cp -R "$WORKDIR/build/xcframeworks/$FW_NAME.xcframework" "$DEST/"

echo ""
echo "==> Done."
ls -lh "$DEST/" | grep xcframework
du -sh "$DEST"/*.xcframework
