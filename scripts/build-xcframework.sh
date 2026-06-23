#!/usr/bin/env bash
#
# Builds spark_frostFFI.xcframework from the Spark Rust repo.
#
# Usage:
#   ./scripts/build-xcframework.sh [IPHONEOS_DEPLOYMENT_TARGET]
#
# Example:
#   ./scripts/build-xcframework.sh 18.6
#
# Prerequisites:
#   - Rust toolchain (rustup)
#   - protoc: brew install protobuf
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SDK_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
XCFW_DIR="$SDK_ROOT/Frameworks/spark_frostFFI.xcframework"

MIN_IOS="${1:-18.0}"
MIN_MACOS="15.0"
SPARK_REPO="https://github.com/buildonspark/spark.git"
SPARK_DIR="/tmp/spark-frost-build"
CARGO="$HOME/.cargo/bin/cargo"
RUSTUP="$HOME/.cargo/bin/rustup"

echo "==> Target: iOS >= $MIN_IOS, macOS >= $MIN_MACOS"

# ── 1. Clone Spark repo ─────────────────────────────────────────────
if [ -d "$SPARK_DIR" ]; then
    echo "==> Spark repo already at $SPARK_DIR, pulling latest..."
    git -C "$SPARK_DIR" pull --ff-only || true
else
    echo "==> Cloning Spark repo..."
    git clone --depth 1 "$SPARK_REPO" "$SPARK_DIR"
fi

# ── 2. Ensure spark-frost-uniffi is in workspace ────────────────────
WORKSPACE_TOML="$SPARK_DIR/signer/Cargo.toml"
if ! grep -q '"spark-frost-uniffi"' "$WORKSPACE_TOML"; then
    echo "==> Adding spark-frost-uniffi to workspace..."
    sed -i '' 's/# *"spark-frost-uniffi"/"spark-frost-uniffi"/' "$WORKSPACE_TOML"
fi

# ── 3. Install Rust targets ────────────────────────────────────────
echo "==> Installing Rust targets..."
"$RUSTUP" target add \
    aarch64-apple-ios \
    aarch64-apple-ios-sim \
    x86_64-apple-ios \
    aarch64-apple-darwin \
    x86_64-apple-darwin

# ── 4. Build for all platforms ──────────────────────────────────────
BUILD_DIR="$SPARK_DIR/signer"
CRATE="spark-frost-uniffi"

build_target() {
    local target="$1"
    local env_key="$2"
    local env_val="$3"
    echo "==> Building $target ($env_key=$env_val)..."
    env "$env_key=$env_val" "$CARGO" build \
        --manifest-path "$BUILD_DIR/Cargo.toml" \
        --release -p "$CRATE" --target "$target"
}

# iOS device
build_target aarch64-apple-ios          IPHONEOS_DEPLOYMENT_TARGET "$MIN_IOS"

# iOS simulator (arm64 + x86_64)
build_target aarch64-apple-ios-sim      IPHONEOS_DEPLOYMENT_TARGET "$MIN_IOS"
build_target x86_64-apple-ios           IPHONEOS_DEPLOYMENT_TARGET "$MIN_IOS"

# macOS (arm64 + x86_64)
build_target aarch64-apple-darwin       MACOSX_DEPLOYMENT_TARGET "$MIN_MACOS"
build_target x86_64-apple-darwin        MACOSX_DEPLOYMENT_TARGET "$MIN_MACOS"

# ── 5. Locate built static libraries ───────────────────────────────
TARGET_DIR="$SPARK_DIR/signer/target"
LIB_IOS="$TARGET_DIR/aarch64-apple-ios/release/libspark_frost.a"
LIB_SIM_ARM="$TARGET_DIR/aarch64-apple-ios-sim/release/libspark_frost.a"
LIB_SIM_X86="$TARGET_DIR/x86_64-apple-ios/release/libspark_frost.a"
LIB_MAC_ARM="$TARGET_DIR/aarch64-apple-darwin/release/libspark_frost.a"
LIB_MAC_X86="$TARGET_DIR/x86_64-apple-darwin/release/libspark_frost.a"

for lib in "$LIB_IOS" "$LIB_SIM_ARM" "$LIB_SIM_X86" "$LIB_MAC_ARM" "$LIB_MAC_X86"; do
    if [ ! -f "$lib" ]; then
        echo "ERROR: Expected library not found: $lib"
        exit 1
    fi
done

# ── 6. Create fat libraries ────────────────────────────────────────
STAGING="/tmp/spark_frostFFI_staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"

echo "==> Creating fat simulator library..."
lipo -create "$LIB_SIM_ARM" "$LIB_SIM_X86" -output "$STAGING/libspark_frost_sim.a"

echo "==> Creating fat macOS library..."
lipo -create "$LIB_MAC_ARM" "$LIB_MAC_X86" -output "$STAGING/libspark_frost_macos.a"

# ── 7. Prepare static-library slices ───────────────────────────────
# spark_frost is a Rust *static* library (libspark_frost.a), so we ship a
# static-library xcframework — NOT a .framework wrapper. A static archive
# wrapped as a .framework gets embedded into the app's Frameworks/ folder
# and is then validated as if it were a dynamic framework: its frozen
# MinimumOSVersion can't be re-targeted by Xcode, so raising the app's
# deployment target above it fails App Store validation (ITMS-90208).
# A static-library xcframework is linked into the app binary and never
# embedded, so that check never applies and any app deployment target works.

# Shared headers dir + a (non-framework) module map so `import spark_frostFFI`
# resolves. Headers are stable and bootstrapped from the current xcframework.
HEADERS="$STAGING/Headers"
mkdir -p "$HEADERS"
cp "$XCFW_DIR/ios-arm64/Headers/spark_frostFFI.h"          "$HEADERS/"
cp "$XCFW_DIR/ios-arm64/Headers/spark_frostFFI-umbrella.h" "$HEADERS/"
cat > "$HEADERS/module.modulemap" << 'MODMAP'
module spark_frostFFI {
  umbrella header "spark_frostFFI-umbrella.h"

  export *
  module * { export * }
}
MODMAP

# Each slice needs the archive under a uniform name in its own directory.
mkdir -p "$STAGING/ios-arm64" "$STAGING/ios-sim" "$STAGING/macos"
cp "$LIB_IOS"                        "$STAGING/ios-arm64/libspark_frostFFI.a"
cp "$STAGING/libspark_frost_sim.a"   "$STAGING/ios-sim/libspark_frostFFI.a"
cp "$STAGING/libspark_frost_macos.a" "$STAGING/macos/libspark_frostFFI.a"

# ── 8. Create xcframework ──────────────────────────────────────────
echo "==> Creating static-library xcframework..."
rm -rf "$STAGING/spark_frostFFI.xcframework"
xcodebuild -create-xcframework \
    -library "$STAGING/ios-arm64/libspark_frostFFI.a" -headers "$HEADERS" \
    -library "$STAGING/ios-sim/libspark_frostFFI.a"   -headers "$HEADERS" \
    -library "$STAGING/macos/libspark_frostFFI.a"     -headers "$HEADERS" \
    -output "$STAGING/spark_frostFFI.xcframework"

# ── 9. Replace existing xcframework ────────────────────────────────
echo "==> Replacing $XCFW_DIR..."
rm -rf "$XCFW_DIR"
mv "$STAGING/spark_frostFFI.xcframework" "$XCFW_DIR"

# ── 10. Verify ──────────────────────────────────────────────────────
echo ""
echo "==> Verifying static-library xcframework..."
LIB="$XCFW_DIR/ios-arm64/libspark_frostFFI.a"
file "$LIB"
echo "    minos (must be <= the consuming app's deployment target):"
otool -l "$LIB" 2>/dev/null | grep -m1 -A2 'LC_BUILD_VERSION' | grep -E 'platform|minos'

echo ""
echo "==> Done! xcframework rebuilt at:"
echo "    $XCFW_DIR"
