#!/bin/bash
# 把 swiftpm/PotteryMaster.swiftpm 打包成 dist/PotteryMaster.swiftpm.zip（上傳到 GitHub Releases 給學生下載）
# 先同步最新的程式碼，再壓縮；不含 .DS_Store
set -euo pipefail
cd "$(dirname "$0")/.."
./tools/sync-swiftpm.sh
rm -rf swiftpm/PotteryMaster.swiftpm/.swiftpm/xcode swiftpm/PotteryMaster.swiftpm/.swiftpm/configuration   # Xcode 建置時產生的暫存
mkdir -p dist
rm -f dist/PotteryMaster.swiftpm.zip
(cd swiftpm && zip -r -X -q ../dist/PotteryMaster.swiftpm.zip PotteryMaster.swiftpm -x "*.DS_Store")
echo "已產生 dist/PotteryMaster.swiftpm.zip（$(du -h dist/PotteryMaster.swiftpm.zip | cut -f1)）"
