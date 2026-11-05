# 正式環境 Supabase 設定流程

> 適用範圍：建立正式環境的 Supabase、GitHub Variables，並把 GitHub Pages 切換到正式環境。完成後登記仍維持關閉。
> 驗收、備份還原與開放登記不在本文件範圍，請見 [TODO](TODO.md) 第 4、5 節與 [驗收紀錄](驗收紀錄.md)。
> 部署方式：一律使用 Supabase Dashboard，不使用 CLI。

## 0. 事前準備

### 機敏資料規則

本文件放在 GitHub 上，依 [機敏資料審查準則](GitHub公開內容機敏資料審查準則.md) 處理：

- 下列值只能貼在 Supabase Dashboard 或 GitHub Settings 中。不要寫進本文件，不要 commit，也不要貼到對話、截圖或 issue。
  - 正式專案的 Project Reference、Project URL
  - Publishable key、Secret key
  - `RATE_LIMIT_KEY`
  - 管理員帳號名稱與密碼
- 本文件中的角括號是 placeholder，操作時換成實際值即可，不要把實際值回填到文件中。

| Placeholder | 意思 | 從哪裡取得 |
| --- | --- | --- |
| `<正式專案>` | 正式 Supabase 專案的名稱 | Dashboard 左上角的專案切換選單 |
| `<帳號名稱>` | 首位管理員的帳號名稱 | 自己決定，規則見 2-2 |
| `<顯示名稱>` | 後台顯示的管理員名稱 | 自己決定，1 到 100 字 |

### 每次操作前先核對專案

開發／測試與正式環境是兩個獨立的 Supabase 專案。每次開啟 SQL Editor、Edge Functions 或 Authentication 頁面前，先確認 Dashboard 左上角顯示的是 `<正式專案>`。

### 正式環境禁止執行的 SQL

`supabase/testing/` 底下的檔案只能在測試專案使用，不要在正式環境執行：

- `enable-activity-preview.sql`
- `mark-test-project.sql`
- `verify-all-no-and-rate-limit.sql`

## 1. Auth 設定

步驟：

- 關閉公開註冊。
- 把最低密碼長度設為 12，與後台規則一致。

※ 1-1

1. 左側選單點 **Authentication**。
2. 在 CONFIGURATION 區塊點 **Sign In / Providers**，位置在 Policies 下面第二個。
3. 頁面上方的 **User Signups** 區塊，把 **Allow new users to sign up** 的開關關閉。
4. 按頁面上的 **Save changes**。如果開關切換後就自動儲存，畫面上沒有出現儲存按鈕也沒關係。

※ 1-2

1. 同一頁往下找到 **Email** provider，點開設定。
2. 找到 **Minimum password length**，填 `12`。
3. 按 **Save**。

## 2. 建立首位管理員的 Auth 使用者

步驟：

- 新增一個使用者，email 填 `<帳號名稱>@accounts.invalid`。
- `staff_profiles` 要等第 3 節 migration 完成後，才在第 4 節建立。

※ 2-1

1. 左側選單點 **Authentication** → **Users**。
2. 點右上角綠色的 **Add user** → **Create new user**。

※ 2-2

1. 填寫：
   - Email：`<帳號名稱>@accounts.invalid`。帳號名稱必須以小寫英文字母開頭，只能包含小寫英文字母、數字、`_`、`-`，長度 3 到 31 字元。
   - Password：自己設一組至少 12 字元、不超過 72 bytes 的臨時密碼。一個中文字約佔 3 bytes。密碼不要貼到任何對話或文件。
   - 勾選 **Auto Confirm User**。
2. 按 **Create user**。
3. 首次登入後台時，系統會要求改密碼，屆時再換成正式密碼。

## 3. 資料庫 migration

> **待定**：執行範圍與順序等開發端確定後再補。
> 已知前提：第 4 節需要 `public.staff_profiles`，因此至少要先執行 `supabase/migrations/202611030001_initial.sql`。

補齊時沿用下列規則：

- 依檔名順序，在 SQL Editor 逐支貼上整份檔案內容並執行。只執行已 commit 進 `main` 的版本。
- 每支只執行一次。執行失敗時先停下來，不要重跑或跳過，先確認錯誤原因。
- 每執行一支，就在下表記錄一列。

| Migration 檔名 | 執行日期 | 執行人 | 結果 |
| --- | --- | --- | --- |
| （待補） | | | |

## 4. 建立首位管理員的 `staff_profiles`

步驟：

- 在 SQL Editor 為第 2 節建立的使用者新增 `staff_profiles`，`role` 設為 `admin`。
- `must_change_password` 使用預設值 `true`，不另外指定。

※ 4-1

1. 確認左上角是 `<正式專案>`。
2. 左側選單點 **SQL Editor** → **New query**。
3. 貼上下面的 SQL，把兩個 placeholder 換成實際值。`<帳號名稱>` 全部小寫，必須和第 2 節相同。

```sql
insert into public.staff_profiles (auth_user_id, username, display_name, role)
select id, '<帳號名稱>', '<顯示名稱>', 'admin'
from auth.users
where email = '<帳號名稱>@accounts.invalid';
```

4. 按 **Run**。結果應顯示 `1 row affected`。若顯示 `0 rows`，代表 email 對不上 Auth 使用者，請回第 2 節核對。
5. SQL Editor 可能自動保存 query。執行完後到左側清單找這個 query，刪除它，避免帳號名稱留在 Dashboard。

## 5. Edge Functions

步驟：

- 設定 secret `RATE_LIMIT_KEY`。
- 部署 `registration`，關閉 JWT 驗證。
- 部署 `staff`，開啟 JWT 驗證。

`SUPABASE_URL` 和 Secret key 由 Supabase 自動提供給 Edge Function，不用手動設定。

※ 5-1 產生並設定 `RATE_LIMIT_KEY`

1. 在本機 PowerShell 7 執行下面這行。它會產生 64 字元的隨機值，直接複製到剪貼簿，不會顯示在畫面上：

   ```powershell
   [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) | Set-Clipboard
   ```

2. Dashboard 左側選單點 **Edge Functions** → **Secrets**。
3. 新增一筆：Name 填 `RATE_LIMIT_KEY`，Value 貼上剪貼簿內容。
4. 按 **Save**。
5. 隨便複製一段其他文字，把剪貼簿蓋掉。

正式與測試專案的 `RATE_LIMIT_KEY` 必須不同，不要沿用測試專案的值。

※ 5-2 部署 `registration`

1. **Edge Functions** → **Functions**，點 **Deploy a new function** → **Via Editor**。
2. Function 名稱填 `registration`。名稱必須完全相同，前端靠這個名稱呼叫。
3. 刪除編輯器裡的範例程式碼，貼上 `supabase/functions/registration/index.ts` 的完整內容。`helpers.test.mjs` 是測試檔，不用部署。
4. 按 **Deploy function**。
5. 部署完成後進入這個 function 的設定頁，把 JWT 驗證關閉。畫面上可能顯示為 **Verify JWT** 或 **Enforce JWT Verification**。這個 function 給公開訪客使用，必須關閉。

※ 5-3 部署 `staff`

1. 同 5-2，Function 名稱改填 `staff`，貼上 `supabase/functions/staff/index.ts` 的完整內容。
2. 部署完成後，到設定頁確認 JWT 驗證是**開啟**狀態。
3. 兩個 function 的 JWT 設定要和測試專案一致。測試專案的設定以 `supabase/config.toml` 為準：`registration` 為 `false`，`staff` 為 `true`。

## 6. GitHub Variables

步驟：

- 在 GitHub repo 設定 `PROD_SUPABASE_URL` 與 `PROD_SUPABASE_PUBLISHABLE_KEY`。
- 這兩個值會寫進公開網站的 `config.js`，本來就是可公開的值。但依審查準則，仍然不寫進 repo 或文件。

※ 6-1 從 Supabase 取得兩個值

1. 確認左上角是 `<正式專案>`。
2. 左側選單點 **Project Settings** → **Data API**，複製 **Project URL**。格式必須是 `https://<一串英數字>.supabase.co`，結尾不能有 `/`。
3. **Project Settings** → **API Keys**，複製 **Publishable key**，開頭必須是 `sb_publishable_`。
4. 不要複製 Secret key 或 `service_role` key。這兩把只能留在 Supabase 內部。

※ 6-2 寫入 GitHub

1. GitHub repo 頁面點 **Settings** → **Secrets and variables** → **Actions**。
2. 切到 **Variables** 分頁，點 **New repository variable**。
3. 新增兩筆：
   - Name：`PROD_SUPABASE_URL`，Value：6-1 第 2 步複製的 URL。
   - Name：`PROD_SUPABASE_PUBLISHABLE_KEY`，Value：6-1 第 3 步複製的 key。
4. 確認名稱沒有拼錯。`DEV_` 開頭的兩筆是測試環境用的，不要改動。

格式不符時，部署 workflow 會在 `Create public site configuration` 這一步失敗，訊息為「缺少有效的 GitHub Pages 公開 Supabase 設定」。

## 7. GitHub Pages 切換到 `main`

一個 repo 只有一個 GitHub Pages 站。目前 `feat/ver-001` 和 `main` 都會部署到同一個網址，誰最後 push，網站就連到誰的 Supabase。上線切換時，改成只由 `main` 部署。切換後測試站下線，之後的測試改用本機 `npm start` 連測試 Supabase。

步驟：

- 從 `.github/workflows/pages.yml` 移除 `feat/ver-001`。
- 確認 Pages 與部署環境的設定允許 `main` 部署。
- 合併進 `main` 後，確認正式站連到正式 Supabase。

※ 7-1 修改 workflow

這一步是程式變更，依分支流程開 PR 合併進 `main`：

```yaml
on:
  push:
    branches: [main]
  workflow_dispatch:
```

※ 7-2 核對 GitHub 設定

1. **Settings** → **Pages**：**Source** 必須是 **GitHub Actions**。
2. **Settings** → **Environments** → **github-pages**：如果有設定 **Deployment branches and tags**，確認清單包含 `main`。

※ 7-3 部署後核對

1. **Actions** 分頁確認 `Deploy GitHub Pages` 由 `main` 觸發，且執行成功。
2. 開啟正式站，畫面上不應出現測試站提示。
3. 瀏覽器開發者工具開啟 `config.js`，確認 `environment` 為 `production`。只用眼睛核對，不要截圖或複製內容。

## 8. 設定核對清單

在 SQL Editor 執行下面兩段查詢，結果都符合預期才算完成。

※ 8-1 站台狀態

```sql
select is_test_environment, is_registration_open
from public.site_settings;
```

預期結果：兩個欄位都是 `false`。

※ 8-2 匿名使用者不能讀取敏感資料

```sql
select t as table_name,
       has_table_privilege('anon', 'public.' || t, 'select') as anon_can_read
from unnest(array[
  'registrations', 'registration_choices', 'registration_hosting', 'staff_profiles',
  'audit_events', 'query_attempts', 'registration_create_limits', 'public_request_limits'
]) as t
where to_regclass('public.' || t) is not null;

select relname as table_name, relrowsecurity as rls_enabled
from pg_class
where relnamespace = 'public'::regnamespace and relkind = 'r'
order by relname;
```

預期結果：第一段每一列的 `anon_can_read` 都是 `false`；第二段每一列的 `rls_enabled` 都是 `true`。

※ 8-3 人工核對

- [ ] 第 1 節：公開註冊已關閉，最低密碼長度為 12。
- [ ] 第 3 節：migration 紀錄表已填完，沒有失敗或跳過的項目。
- [ ] 第 4 節：用首位管理員登入正式站後台，系統要求改密碼；改完後可以進入後台。
- [ ] 第 5 節：兩個 function 都已部署，JWT 設定正確。正式站首頁能載入活動與區別清單。
- [ ] 第 6、7 節：正式站由 `main` 部署，`config.js` 的 `environment` 為 `production`。
- [ ] 8-1、8-2 查詢結果符合預期。

全部打勾後，接著進行 [TODO](TODO.md) 第 4 節的 smoke test 與驗收，並把結果記在 [驗收紀錄](驗收紀錄.md)。
