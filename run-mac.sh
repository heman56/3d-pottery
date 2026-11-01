#!/bin/bash
# 在這台 Mac 上直接執行（Mac Catalyst，不經過模擬器）：產生專案、編譯、簽章、開啟
set -euo pipefail
cd "$(dirname "$0")"

xcodegen generate
xcodebuild -project PotteryMaster.xcodeproj -scheme PotteryMaster \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO -quiet build

APP="build/Build/Products/Debug-maccatalyst/PotteryMaster.app"
codesign --force --deep --sign - "$APP"   # 本機自用的臨時簽章
open "$APP"
