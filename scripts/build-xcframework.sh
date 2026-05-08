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

# ── 7. Prepare framework slices ────────────────────────────────────
# We wrap each static library in a .framework directory structure
# to match the existing xcframework layout.

create_framework() {
    local dir="$1"
    local lib="$2"
    local min_os="$3"
    local fwk="$dir/spark_frostFFI.framework"

    mkdir -p "$fwk/Headers" "$fwk/Modules"
    cp "$lib" "$fwk/spark_frostFFI"

    # Copy headers from existing xcframework (or from Spark repo if available)
    cp "$XCFW_DIR/ios-arm64/spark_frostFFI.framework/Headers/"* "$fwk/Headers/"
    cp "$XCFW_DIR/ios-arm64/spark_frostFFI.framework/Modules/module.modulemap" "$fwk/Modules/"

    # Create Info.plist
    cat > "$fwk/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>spark_frostFFI</string>
	<key>CFBundleIdentifier</key>
	<string>com.spark.frostFFI</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>spark_frostFFI</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>MinimumOSVersion</key>
	<string>${min_os}</string>
</dict>
</plist>
PLIST
}

echo "==> Packaging framework slices..."
create_framework "$STAGING/ios-arm64"              "$LIB_IOS"                       "$MIN_IOS"
create_framework "$STAGING/ios-arm64_x86_64-sim"   "$STAGING/libspark_frost_sim.a"  "$MIN_IOS"
create_framework "$STAGING/macos-arm64_x86_64"     "$STAGING/libspark_frost_macos.a" "$MIN_MACOS"

# ── 8. Create xcframework ──────────────────────────────────────────
echo "==> Creating xcframework..."
rm -rf "$STAGING/spark_frostFFI.xcframework"
xcodebuild -create-xcframework \
    -framework "$STAGING/ios-arm64/spark_frostFFI.framework" \
    -framework "$STAGING/ios-arm64_x86_64-sim/spark_frostFFI.framework" \
    -framework "$STAGING/macos-arm64_x86_64/spark_frostFFI.framework" \
    -output "$STAGING/spark_frostFFI.xcframework"

# ── 9. Replace existing xcframework ────────────────────────────────
echo "==> Replacing $XCFW_DIR..."
rm -rf "$XCFW_DIR"
mv "$STAGING/spark_frostFFI.xcframework" "$XCFW_DIR"

# ── 10. Verify ──────────────────────────────────────────────────────
echo ""
echo "==> Verifying minos in built binary..."
otool -l "$XCFW_DIR/ios-arm64/spark_frostFFI.framework/spark_frostFFI" 2>/dev/null \
    | grep -A 3 'LC_BUILD_VERSION' | head -8

echo ""
echo "==> Done! xcframework rebuilt at:"
echo "    $XCFW_DIR"
