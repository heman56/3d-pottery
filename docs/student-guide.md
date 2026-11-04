# 製陶大師：下載與開啟說明（學生版）

這份說明教你把「製陶大師」下載到 iPad，用 Swift Playgrounds 打開並執行。大約 5 分鐘。

## 需要什麼

- 一台 iPad，系統是 **iPadOS 18 以上**（設定 → 一般 → 軟體更新可以查）
- 免費的 App：**Swift Playgrounds**（App Store 搜尋即可）
- 網路（只有下載時需要）

## 步驟

### 1. 下載

1. 在 iPad 的 Safari 打開老師給你的下載頁（GitHub 的 **Releases** 頁面）。
2. 找到最新版本，點 **`PotteryMaster.swiftpm.zip`** 下載。
3. 如果 Safari 問你要不要下載，按「下載」。

### 2. 解壓縮

1. 打開「檔案」App → 「下載項目」資料夾。
2. 點一下 `PotteryMaster.swiftpm.zip`，iPad 會自動解開，出現一個叫 **`PotteryMaster`**（或 `PotteryMaster.swiftpm`）的檔案。
3. 想放在別的地方可以長按它，選「移動」，例如移到「我的 iPad」裡的資料夾。

### 3. 用 Swift Playgrounds 打開

1. 點一下剛才解開的 `PotteryMaster`。
2. 如果沒有自動開啟，長按它 → 「分享」→ 選 **Swift Playgrounds**。
3. 也可以先打開 Swift Playgrounds，在首頁找「打開檔案」之類的項目，選擇它。
4. 打開後，左邊會列出程式檔（`ContentView`、`PotteryModel` 等），另有一個「資源」。

### 4. 執行

- 按畫面右上角的 **執行（▶）**，App 會直接在 iPad 上跑起來，也可以用預覽視窗看。
- 第一次編譯需要一點時間，請等一下。
- 看到轉盤和一塊泥團，就成功了！

怎麼玩，請看 [操作手冊](manual.md)。

## 常見問題

| 問題 | 怎麼辦 |
|---|---|
| 解壓後找不到資料夾 | 到「檔案」App 的「下載項目」，或用搜尋輸入 `PotteryMaster` |
| 點了沒反應 | 長按 → 分享 → Swift Playgrounds |
| 說系統版本太舊 | iPad 要更新到 iPadOS 18 以上；舊 iPad 不支援 |
| 編譯很久或失敗 | 關掉其他 App 後再試一次；仍然失敗，把畫面截圖給老師 |
| 想改程式 | 直接在 Swift Playgrounds 左邊點程式檔就能改；改壞了就重新下載一份 |
| 作品存在哪裡 | App 右上角 ☰ → 「儲存」，存到「檔案」App 裡你選的位置 |
| 老師更新了版本 | 回到下載頁，下載新的 ZIP，用同樣的步驟再打開 |

## 給老師的備註

- 這份 ZIP 是用 `tools/package-swiftpm.sh` 產生的（輸出在 `dist/PotteryMaster.swiftpm.zip`），之後上傳到 GitHub Releases。
- `swiftpm/PotteryMaster.swiftpm` 裡的 `.swift` 檔是從 `Sources/` 同步過來的，改了 `Sources/` 後，打包腳本會自動先同步。
- 學生在 iPad 的「檔案」App 解壓縮、用 Swift Playgrounds 開啟這幾步，請老師先自己走過一次，確認和上面描述一致。
