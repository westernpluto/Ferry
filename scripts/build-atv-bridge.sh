#!/usr/bin/env bash
# Builds the Apple TV bridge (Rust, Packages/ATVBridge) for iOS device + simulator and packages
# it as Frameworks/ATVBridge.xcframework. Run before `xcodegen generate`.
# Requires macOS with Xcode and rustup.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE="$ROOT/Packages/ATVBridge"
OUT="$ROOT/Frameworks/ATVBridge.xcframework"
export IPHONEOS_DEPLOYMENT_TARGET=16.0

TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios)
rustup target add "${TARGETS[@]}"

cd "$BRIDGE"
for t in "${TARGETS[@]}"; do
  echo "==> cargo build --target $t"
  cargo build --release --locked --target "$t"
done

LIB=libatvbridge.a
SIM_DIR="$BRIDGE/target/ios-sim-universal"
mkdir -p "$SIM_DIR"
lipo -create -output "$SIM_DIR/$LIB" \
  "$BRIDGE/target/aarch64-apple-ios-sim/release/$LIB" \
  "$BRIDGE/target/x86_64-apple-ios/release/$LIB"

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework \
  -library "$BRIDGE/target/aarch64-apple-ios/release/$LIB" -headers "$BRIDGE/include" \
  -library "$SIM_DIR/$LIB" -headers "$BRIDGE/include" \
  -output "$OUT"

echo "==> Built $OUT"
