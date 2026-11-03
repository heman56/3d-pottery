#!/bin/bash
# 編譯並執行離屏渲染測試（macOS，用真正的 GPU，不經過模擬器）
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-/tmp/render-test.png}"
EXPONENT="${2:-0}"
SUN="${3:-0}"
BIN="$(mktemp -d)/render-test"
swiftc -O -o "$BIN" \
  Sources/Materials.swift Sources/Environment.swift tools/render-test/main.swift \
  -framework RealityKit -framework Metal -framework AppKit -framework ImageIO 2>&1 | grep -E "error" || true
"$BIN" Resources/brown_photostudio_03_1k.hdr "$OUT" "$EXPONENT" "$SUN"
