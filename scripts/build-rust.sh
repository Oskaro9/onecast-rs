#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$ROOT_DIR/core"
GEN_DIR="$ROOT_DIR/app/Generated"
FFI_INC_DIR="$ROOT_DIR/app/Sources/OneCastCoreFFI/include"
SWIFT_CORE_DIR="$ROOT_DIR/app/Sources/OneCastCore"
LIB_DIR="$ROOT_DIR/app/Libs"

mkdir -p "$GEN_DIR" "$FFI_INC_DIR" "$SWIFT_CORE_DIR" "$LIB_DIR"

echo "==> Building onecast-core (aarch64-apple-darwin, release)..."
cargo build --manifest-path "$CORE_DIR/Cargo.toml" --release --target aarch64-apple-darwin

STATIC_LIB="$CORE_DIR/target/aarch64-apple-darwin/release/libonecast_core.a"
cp "$STATIC_LIB" "$LIB_DIR/libonecast_core.a"

echo "==> Generating Swift UniFFI bindings..."
cargo run --manifest-path "$CORE_DIR/Cargo.toml" --bin uniffi-bindgen -- \
    generate --library "$STATIC_LIB" \
    --language swift \
    --out-dir "$GEN_DIR"

cp "$GEN_DIR/onecast_coreFFI.h" "$FFI_INC_DIR/onecast_coreFFI.h"
cp "$GEN_DIR/onecast_coreFFI.modulemap" "$FFI_INC_DIR/module.modulemap"
cp "$GEN_DIR/onecast_core.swift" "$SWIFT_CORE_DIR/onecast_core.swift"

echo "==> Done."
