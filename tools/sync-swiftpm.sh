#!/bin/bash
# 把 Sources/ 的 .swift 檔同步到 swiftpm/PotteryMaster.swiftpm（Swift Playgrounds 要求程式碼放在套件根目錄）
# Package.swift、Info-additions.plist、Resources/ 只在 swiftpm 裡維護，不會被覆蓋
set -euo pipefail
cd "$(dirname "$0")/.."
cp Sources/*.swift swiftpm/PotteryMaster.swiftpm/
echo "已同步 $(ls Sources/*.swift | wc -l | tr -d ' ') 個 .swift 檔到 swiftpm/PotteryMaster.swiftpm"
