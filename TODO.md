# ICTC 2027 登記系統 TODO

> 更新日期：2026-11-03  
> 目標：11/5 完成正式環境驗收後公開；核心流程或資料安全驗收未通過則延後。

## 現在先做

- [x] Q42：11/5 前凍結功能範圍，只接受 bug、安全與文字內容修正。
- [x] Q43：建立規劃檔中的全部活動，未確認項目保持未公開。
- [ ] 更新開發環境的 Node.js。現有 `v20.19.4` 已 EOL，不使用於本專案；改用已修補的 Node 24 LTS。
- [ ] 確認 `node --version`、`npm --version`，再建立最小 `package.json`。
- [ ] 從 `feat/ver-001` 建立新的功能分支，不直接在 `feat/ver-001` 開發。
- [ ] 依 Supabase 建置 wizard，從頭建立開發專案並驗證連線。
- [ ] 建立最小網站、migration、RLS、Edge Function 與 Playwright 骨架。

## 分支與部署流程

每次開發都使用以下流程：

```text
feature branch
    ↓
feat/ver-001（測試環境）
    ↓
main（正式環境，由 GitHub Pages 部署）
```

- `feature branch` 完成並測試後合併至 `feat/ver-001`。
- `feat/ver-001` 完成測試環境驗收後才合併至 `main`。
- GitHub Pages 正式站只部署 `main`。
- 部署 artifact 只包含網站成品，不包含 SQL、測試、`node_modules`、規劃文件或 secrets。

## Supabase 建置 wizard

使用者需要從零開始逐步操作；不得假設已熟悉 Supabase Dashboard。

### 開發專案

- [ ] 登入或建立 Supabase 帳號。
- [ ] 建立獨立的開發／測試專案。
- [ ] 確認 project name、region 與資料庫密碼保存位置。
- [ ] 取得 project URL、publishable／anon key 與 project reference。
- [ ] 將公開設定寫入 Git 忽略的本機設定檔。
- [ ] secret 與資料庫密碼不得寫入 repo、前端設定或對話紀錄。
- [ ] 連接 Supabase CLI。
- [ ] 套用 migration、RLS、seed 與 Edge Functions。
- [ ] 驗證靜態頁面能連接開發專案。

### 正式專案

- [ ] 11/5 公開前建立獨立的正式專案。
- [ ] 使用相同 migration 與 seed 重建，不在 Dashboard 人工重做 schema。
- [ ] 設定 GitHub Pages 所需的公開設定與 Edge Function secrets。
- [ ] 11/5 公開前部署正式環境並完成驗收。

## Node.js 與 npm 安全原則

Node.js 與 npm 只用於開發工具；正式 GitHub Pages 不執行 Node.js server。

- [ ] 使用仍受支援且已包含 2026-10 安全修補的 Node 24 LTS。
- [ ] 只安裝必要工具：Playwright、靜態伺服器及 Supabase CLI。
- [ ] 套件使用精確版本，不使用 `^` 或 `~` 自動升級。
- [ ] 提交 `package-lock.json`，後續使用 `npm ci`。
- [ ] 執行 `npm audit` 並檢查直接與間接相依套件。
- [ ] 本機靜態伺服器只綁定 `127.0.0.1`。
- [ ] 瀏覽器使用的 Supabase library 固定明確版本。

## 11/5 上線範圍

### 公開流程

- [ ] 公開登記頁：姓名、區與當下所有公開活動。
- [ ] 每個公開活動都須明確選擇參加或不參加，且至少參加一項。
- [ ] 完成頁顯示流水號與一次性查詢碼，提供複製及列印。
- [ ] 未確認已保存查詢碼時，離開頁面須提醒。
- [ ] 查詢、修改、取消與恢復流程。
- [ ] 截止後仍可查看，不能自行修改或恢復。
- [ ] 同名同區允許送出，公開頁不透露既有紀錄，後台標示疑似重複。

### 查詢碼

- [ ] 使用 5 字元小寫英數混合查詢碼。
- [ ] 排除容易混淆的 `0`、`o`、`1`、`i`、`l`。
- [ ] 輸入自動轉成小寫並忽略空白。
- [ ] 資料庫只保存以伺服端秘密值保護的雜湊值，查詢碼不得出現在 URL、CSV 或 audit 中。
- [ ] 建立成功後以 `sessionStorage` 傳至 `success.html`，關閉分頁後消失。

### 查詢碼遺失

- [ ] 11/5 公開前提供部署維護者專用的安全重設指令。
- [ ] 指令輸入流水號後產生新查詢碼、使舊碼失效並寫入 audit。
- [ ] 指令從本機安全讀取 secret，不把 service role key 放進網站。
- [ ] 完整服事者重設頁面延後。

### 安全界線

- [ ] 所有公開登記操作經 Edge Function 驗證。
- [ ] 啟用 RLS；公開訪客不能直接讀取登記、選擇、staff profile 或查詢碼雜湊。
- [ ] 建立登記使用 honeypot、最短合理填寫時間及 `create_request_id`。
- [ ] 查詢失敗使用一致訊息，不透露查詢碼是否存在或接近正確。
- [ ] 查詢碼驗證加入服務端限速；錯碼達全站異常門檻時暫停公開查詢與修改，並提供維護者解除流程。上線前測試觸發與解除。
- [ ] 不保存 IP 或 IP 雜湊。
- [ ] 設定全站異常門檻、紀錄及 `is_registration_open` 緊急關閉開關。
- [ ] 加入 `robots` 禁止索引；不得把它視為存取控制。
- [ ] Cloudflare Turnstile 保留接口但 11/5 暫不啟用，後續可直接加入。

### Audit

- [ ] 建立 append-only `audit_events`。
- [ ] 記錄公開建立、修改、取消、恢復，以及後台異動。
- [ ] 保存操作者、動作、目標、時間與非機密欄位的修改前後值。
- [ ] 不保存密碼、查詢碼、查詢碼雜湊或防機器人憑證。
- [ ] Audit 僅供 `admin` 查看；查看畫面延後。

## 資料與狀態規則

- [ ] 開放條件使用 `is_registration_open`；截止時間為空代表無期限，有設定時才檢查截止。
- [ ] 新增活動後，舊登記儲存修改或恢復時，必須回答當下所有公開活動。
- [ ] 建立、修改、取消、恢復及匯入狀態更新使用資料庫交易。
- [ ] 活動、區與系統設定保存在資料庫，不寫死於 HTML。
- [ ] 未確認的活動不得顯示為已公告。

## 測試與驗收

### 11/5 公開前

- [ ] 資料庫 migration 可重跑。
- [ ] RLS 允許與拒絕案例通過。
- [ ] Playwright 覆蓋建立、查詢、修改、取消、恢復、錯誤查詢碼與截止規則。
- [ ] 自動測試 Desktop Chromium、Desktop WebKit、Mobile Chrome 與 Mobile Safari 模擬。
- [ ] 測試資料使用唯一 run ID，結束後只清除該次建立的資料。
- [ ] GitHub Actions 可延後；可重複執行的本機測試不能延後。

### 11/5 公開前的正式環境

- [ ] 使用 iPhone、iPad 或 Mac 的實際 Safari 完成 smoke test。
- [ ] 驗證 GitHub Pages、正式 Supabase、RLS 與 Edge Functions。
- [ ] 驗證安全重設查詢碼指令。
- [ ] 驗證備份及 rollback 程序。
- [ ] 外觀小問題可記錄後修；核心流程與資料安全問題必須修正。

### 11/5 公開前清除測試資料

- [ ] 清除前顯示正式 project reference、目標資料表與筆數。
- [ ] 先匯出可還原備份並取得人工確認。
- [ ] 清除所有測試登記、選擇、相關 audit 與測試限速資料。
- [ ] 保留活動、區與系統設定。
- [ ] 流水號重設，使 11/5 第一筆正式登記為 `38-0001`。
- [ ] 清除後確認有效登記數為 0，再開放入口。

## 初始活動策略

建立規劃檔中的全部活動，以下未確認項目保持未公開：

- 青年大會的時間與地點。
- 主日晚間愛筵是否舉行。
- 尚未公告的用餐時間與地圖連結。

Q43 已確認。

## 11/5 後可延後項目

- 完整服事者／管理員登入與帳號管理。
- 後台名單、搜尋、統計與 CSV。
- 管理員活動、時間表、區及截止時間設定頁。
- Audit 查看頁面。
- Cloudflare Turnstile 正式設定與啟用。
- GitHub Actions 完整 CI。
- 進階 rate limiting 服務。

## 已定案摘要

- 靜態 HTML、CSS、原生 JavaScript，runtime 無 build step。
- npm 只負責開發工具、測試與本機伺服器。
- 開發／測試與正式環境使用不同 Supabase 專案。
- SQL migration 進版控並用 Supabase CLI 套用。
- 公開操作經 Edge Function；狀態轉換使用受控 RPC／服務端流程。
- 第一個垂直切片包含 schema、RLS、建立、完成、查詢、修改、取消及測試。
- 手機優先，測近期 Chrome、Edge 與 Safari；不設 WCAG 驗收項目。
