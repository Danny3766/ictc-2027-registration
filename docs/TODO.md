# ICTC 2027 登記系統 TODO

> 更新日期：2026-11-14。已完成並發布的項目已刪除，過程與結果見 [驗收紀錄](驗收紀錄.md)、[需求討論與決策紀錄](需求討論與決策紀錄.md) 與 git 歷史。

## 目前狀態

| 環境 | 前端 | 資料庫 migration | Edge Function |
| --- | --- | --- | --- |
| 正式站 | `main`，PR #41（2026-11-08） | 套用至 `202611070001` | `staff` 為 2026-11-08 版 |
| 測試站 | `develop`，PR #58（2026-11-13） | 確定套用至 `202611100004`（2026-11-10）；`202611110001`～`202611110004` 未記錄 | `staff` 為 2026-11-10 版之後未記錄 |

`develop` 比 `main` 多 PR #42～#59，正式站下一次發布要一起帶上。

## 進行中：正式站發布時保留既有登記資料（`fix/preserve-prod-registrations`）

決策見[需求討論與決策紀錄](需求討論與決策紀錄.md)「2026-11-14 正式站發布時保留既有登記資料」。

- [x] 從 `develop` 建立分支，先記錄決策與文件。
- [ ] `202611090002`：回填只處理兒童，沒有身分的登記保留空白（Q7）。
- [ ] `202611100004`：刪除改寫既有登記接待答案的區塊（Q8）。
- [ ] `202611110003`：回填拿掉「非一般身分一律標為無效」的條件，只依審計紀錄判斷系統自動產生的「否」（Q8）。
- [ ] 新增 `202611140001_student_identity_reserved.sql`：學生加入保留規則與刪除保護（Q11、Q12）。
- [ ] 後台：學生不顯示刪除、不能改啟用與開放選擇；「學生統計身分」仍可選學生；更新提示文字。補對應測試。
- [ ] 本機隔離資料庫從 `main` 的結構重播全部新 migration，用虛構舊登記逐欄比對；同時驗證沒有身分的登記在公開修改、後台名單、統計與 CSV 的行為，以及學生保留接機答案時的統計與 CSV。
- [ ] 準備正式站唯讀查詢：發布前後比對（Q4）、學生接待答案預覽（Q2），以及測試站套用 `202611140001` 前的檢查。
- [ ] 送 PR 至 `develop`；測試站補套用 `202611140001` 並發布前端。

## 測試站：補齊部署並驗收

前端已更新到 PR #58，以下確認後端跟上。

- [ ] 名單身分篩選與學生統計（PR #57）：依序套用 `202611130001_student_statistics_identity.sql` → `verify-student-statistics-identity.sql` → staff Edge Function。驗收名單身分篩選（含 PostgREST 篩選）與學生統計，再由管理員指定學生統計身分；首次部署不自動指定。staff Edge Function 更新前，舊版會忽略名單身分篩選並回傳整份名單，不要據此驗收。本機驗證結果見[用餐身分管理](用餐身分管理.md)「指定學生身分統計」「名單身分篩選」。
- [ ] 確認測試專案已依序套用 `202611110001_staff_performance.sql`、`202611110002_conference_import_status.sql`、`202611110003_survey_identities.sql`、`202611110004_identity_reorder.sql`，並部署 `develop` 上的 `registration`、`staff` Edge Function；未套用的依序補上。`202611110003` 前先關閉登記，完成後恢復原開放狀態。每支套用後執行對應的 `verify-staff-performance.sql`、`verify-conference-import-status.sql`、`verify-survey-identities.sql`、`verify-identity-reorder.sql`。結果記在[驗收紀錄](驗收紀錄.md)。
- [ ] 在測試專案執行尚未留紀錄的驗證腳本：`verify-child-registration.sql`、`verify-child-type.sql`、`verify-registration-identities.sql`、`verify-independent-identity-prices.sql`、`verify-unified-identity.sql`。
- [ ] 請專案負責人與弟兄們驗收 PR #43～#58 的功能，各項細節見對應文件：
  - 兒童報名、兒童類型與親子對應、名單兒童條件：[需求討論與決策紀錄](需求討論與決策紀錄.md)「2026-11-09 兒童報名」「兒童類型」。
  - 身分別管理、各身分價格、統一身分別、身分標籤、拖拉排序：[用餐身分管理](用餐身分管理.md)。
  - 接待題依身分開放、藍色提醒區塊、查詢結果外框：[接待身分設定](接待身分設定.md)。
  - 活動影響大會匯入狀態：[大會匯入狀態驗證](大會匯入狀態驗證.md)。
  - 後台效能與身分別區塊、公開表單缺漏欄位提示。
  - 名單身分篩選、指定學生身分統計（PR #57，後端部署後驗收）：[用餐身分管理](用餐身分管理.md)。
  - 公開查詢頁修改時鎖定查詢欄位、漏選活動紅框（PR #58）：[需求討論與決策紀錄](需求討論與決策紀錄.md)「2026-11-13 公開查詢頁修改時鎖定查詢欄位」「2026-11-13 公開頁漏選活動的紅框提示」。
- [ ] 確認兒童類型標籤色碼（學齡前粉色底、國小粉藍底）。

## 進行中：後台登記詳情的唯讀樣式（`fix/admin-detail-readability`）

決策見[需求討論與決策紀錄](需求討論與決策紀錄.md)「2026-11-14 後台登記詳情的唯讀樣式」。

- [x] 從 `develop` 建立分支，先記錄決策。
- [x] 登記詳情查看狀態：選中的答案改實心膠囊（參加、是、家人已登記用綠色，不參加、否用深灰色），沒選的淡化；姓名、區、身分別改深色文字；未回覆的活動顯示「未回覆」標籤。圓點只做視覺隱藏，螢幕報讀器仍讀得到選中的答案。編輯狀態不變。`openRegistration()` 在查看時替表單加上 `viewing` class，樣式只在這個 class 下生效。
- [x] `tests/staff.spec.mjs`「editing an old registration leaves a newer activity unanswered」補查看與編輯兩種狀態的樣式檢查，並確認查看時選中的 radio 仍可由 role 找到且為已選，桌機／手機 Chromium 與 WebKit 共 4 項通過。`staff`、`read-only`、`identities`、`survey-identities` 在 desktop-chromium 共 150 項，149 項通過；「the 身分別 checklist filters…」整批平行執行時版面量測失敗，未改動的程式碼同樣失敗，單獨重跑 3 次通過。已檢視桌機與手機 Chromium 截圖：開家「是」與接待人數、家人已登記、接機否、編輯狀態。
- [ ] 送 PR 至 `develop`，測試站只需發布前端。

## 正式站：下一次發布（`develop` → `main`）

含 migration，依[正式環境設定流程](正式環境setup.md) 9-3 關閉登記後更新。測試站驗收通過才執行。

- [ ] 依 9-3 關閉登記，通知服事者。
- [ ] 留底：後台下載報名登記 CSV 與統計 CSV，執行發布前後比對查詢並記下結果（不含姓名）。
- [ ] 執行 `supabase/testing/preview-hosting-general-only.sql`（唯讀），請專案負責人確認學生身分登記的接待答案。結果含個資，不貼到 repo、PR 或對話。
- [ ] 正式專案依序套用 `202611090001`～`202611140001` 共 13 支 migration，每支記在[正式環境設定流程](正式環境setup.md)第 3 節。任一支失敗就停下，保持關閉登記。
- [ ] 部署 `registration` 與 `staff` Edge Function，Verify JWT 依第 5 節設定。
- [ ] 以 **Create a merge commit** 合併 `develop` → `main`，依 7-4、8 節核對，結果記在[驗收紀錄](驗收紀錄.md)。
- [ ] 再執行一次發布前後比對查詢，兩次結果相同才繼續。
- [ ] 管理員在正式站後台：把 `general` 改名「聖徒」、學生統計身分指定學生、開家接待可填身分加入學生（接機維持只有聖徒），確認「其中學生」人數。
- [ ] 重新開放登記，通知服事者維護結束。
- [ ] 在 LINE 群組公告：已幫兒童登記的家庭，用「查詢或修改登記」選擇兒童類型並填家長姓名。

## 上線前移除的多餘程式碼與欄位

各項都用新 migration 處理，先在測試專案驗證，再隨正式站發布。

- [ ] 刪除 `registration_hosting.family_count`、`note`、約束 `registration_hosting_removed_fields`，以及 `registration_hosting.pickup_count`。執行前確認兩站的 Edge Function 都已是不讀這些欄位的版本。
- [ ] 移除已無呼叫者的舊接待流程：`registration_audience_valid`（兩個多載）、`registration_skipping_hosting`、`registration_child_save`、`registration_child_answers_put`，以及 `create_registration`、`update_registration`、`staff_create_registration`、`staff_update_registration` 中 `registration.surveys_managed` 未開啟時的接待分支（該分支比對的 `registration_hosting_get` 已多帶 `answer_valid`）；`staff_save_reception_settings` 可改由 staff Edge Function 直接呼叫 `staff_save_reference`。
- [ ] 由專案負責人判斷尖峰已過後，把同一來源限流調回 60，同步更新 `verify-all-no-and-rate-limit.sql` 與 9-3 的唯讀查詢。

## 待決定

- [ ] 公開頁未儲存時切出再切回接待題，要維持清空重答，還是改成不動答案並移除 `reset` 標記；見[接待身分設定](接待身分設定.md)「待決定」第 1 項。
- [ ] 身分加進某題可填清單時，是否比照活動報名對象先提醒受影響人數；見[接待身分設定](接待身分設定.md)「待決定」第 2 項。
- [ ] 確認大會系統欄位後，評估用餐身分變更是否要改為「需重新匯入」。

## 正式環境維運

- [ ] 訂出備份的頻率與存放位置，並演練一次還原。
- [ ] 依方案限制定期開啟正式站或後台，避免專案因閒置暫停；發現暫停就到 Dashboard 恢復。
- [ ] 用 iPhone、iPad 或 Mac 的實際 Safari 完成正式站 smoke test。
- [ ] 在能直連 Supabase 的網路重跑 `rls.spec.mjs`，確認 RLS 允許與拒絕案例。
- [ ] 補記上線前必驗、但[驗收紀錄](驗收紀錄.md)沒有結果的帳號、限速與權限項目；清單在維護者本機的稽核紀錄，不寫進 repo。
- [ ] 測試資料清理：清除前確認環境、資料表與筆數，先備份並取得人工確認，保留活動、區與系統設定。

## 後台改善

- [ ] 取消公開活動前提示受影響的登記人數（[系統架構規劃](系統架構規劃.md)第 4 節）。
- [ ] 為 `staff` Edge Function 的改名同步登入識別、設定密碼流程補上注入假 Supabase client 的單元測試。
- [ ] 評估改用不會變的內部識別作為 Auth 登入 email，改名時只更新 `staff_profiles`。

## 可延後項目

- 後台離開前提醒：有未儲存的修改時，重新整理或關閉分頁前先確認；需判斷 8 個功能區塊的表單是否改過，另開功能分支。
- 後台左側選單：原 `feat/admin-sidebar-layout` 分支已不存在，要做時重新開分支。
- Cloudflare Turnstile：以公開設定提供 site key、伺服端 secret 驗證 token，用新 migration 調整防護；測試與正式環境分開設定。未完成前不讓公開流程依賴 Turnstile。
- GitHub Actions 完整 CI。
- 進階 rate limiting 服務。
- 後台統計的匯入狀態人數（待匯入、已匯入、需重新匯入）：大會匯入流程確定後再做。

## 分支與部署流程

`feat/*` 從 `develop` 建立 → PR 進 `develop` → 測試站驗收 → PR 進 `main`（**Create a merge commit**）。只有 `main` 部署正式站；測試站是獨立網址。細節見[正式環境設定流程](正式環境setup.md)第 9 節。

## 已定案摘要

- 靜態 HTML、CSS、原生 JavaScript，runtime 無 build step；npm 只負責開發工具、測試與本機伺服器。
- 開發／測試與正式環境使用不同 Supabase 專案；資料庫遷移以版本控制管理，依核准的部署程序套用。
- 公開操作經 Edge Function；狀態轉換使用受控 RPC／服務端流程。
- 手機優先，測近期 Chrome、Edge 與 Safari；不設 WCAG 驗收項目。
