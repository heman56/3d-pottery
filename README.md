# 製陶大師

一個給學生玩的 3D 拉坯小遊戲：用手指在轉盤上捏出陶器，換花紋、上釉、入窯燒製，最後存檔或匯出 3D 模型。
使用 Swift、SwiftUI、RealityKit 製作，可在 iPad、iPhone 和 Mac（Mac Catalyst）上執行。

## 學生

- [下載與開啟說明](docs/student-guide.md)：下載 `PotteryMaster.swiftpm.zip`，用 Swift Playgrounds 在 iPad 上打開
- [操作手冊](docs/manual.md)：怎麼捏、上花紋、燒、存檔

## 專案結構

| 路徑 | 內容 |
|---|---|
| `Sources/` | 所有程式碼（唯一的來源） |
| `Resources/` | 環境光 HDRI 與素材授權說明 |
| `project.yml` | XcodeGen 設定，產生 `PotteryMaster.xcodeproj` |
| `swiftpm/PotteryMaster.swiftpm` | Swift Playgrounds 版本，程式碼從 `Sources/` 同步 |
| `tools/` | 同步、打包、離屏渲染測試的腳本 |
| `docs/` | 操作手冊、學生說明 |

## 開發（Mac）

```bash
./run-mac.sh                    # 編譯並以 Mac Catalyst 執行
./tools/sync-swiftpm.sh         # 把 Sources/*.swift 同步到 .swiftpm
./tools/package-swiftpm.sh      # 打包成 dist/PotteryMaster.swiftpm.zip（上傳到 GitHub Releases）
```

需要 Xcode 16 以上與 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

## 授權

[MIT License](LICENSE)：學生和老師都可以自由使用、修改、分享，教學與課堂使用都不需要另外申請。

## 素材

環境光 HDRI 來自 Poly Haven，授權 CC0，詳見 [Resources/CREDITS.md](Resources/CREDITS.md)。
