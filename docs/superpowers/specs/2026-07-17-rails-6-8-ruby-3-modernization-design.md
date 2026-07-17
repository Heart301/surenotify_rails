# surenotify_rails 現代化設計：支援 Rails 6/7/8 與 Ruby 3+

日期：2026-07-17

## 目標

將 surenotify_rails gem（電子豹 Surenotify 的 Action Mailer adapter）更新為可在
Rails 6.1、7.x、8.0 與 Ruby 3.0+ 環境正常安裝與運作，並建立可驗證相容性的測試與 CI。

## 背景

此 gem 從 mailgun_rails fork 而來，目前狀態：

- gemspec 依賴 `actionmailer >= 4.2.11`、`rest-client >= 2.0.2`、`rspec ~> 2.14.1`，無 `required_ruby_version`
- rest-client 已多年未維護（最後版本 2019 年），在 Ruby 3.x 有相容性風險
- spec 仍是 mailgun_rails 舊測試（目錄 `spec/lib/mailgun_rails/`、RSpec 2 `stub` 語法、URL 指向 mailgun），並依賴一個 Rails 3 時代的 dummy app，新環境無法執行
- CI 只有已停用的 `.travis.yml` 與舊 `.gemfiles/`（rails 4.0–5.0）
- 既有 bug：`deliverer.rb` 中 `surenotifyRails::Attachment` 大小寫錯誤，有附件時必 crash
- 附件功能實際上從未正常運作：`Attachment`（StringIO）被放進 `JSON.dump`，
  只會產生 `"#<SurenotifyRails::Attachment:0x...>"` 字串，API 收不到真正的附件內容

## 設計決策（已與使用者確認）

1. **HTTP client**：移除 rest-client，改用 Ruby 內建 `Net::HTTP`（零外部依賴）
2. **測試**：以 RSpec 3 + WebMock 重寫 spec，移除 dummy app 與舊 mailgun spec
3. **CI**：新增 GitHub Actions matrix（Rails × Ruby），移除 Travis 與舊 gemfiles
4. **版本**：升為 1.0.0
5. **附件**：移除附件支援（API 文件證實不支援附件），README 註明
6. **新功能**（依 https://newsleopard.com/surenotify/api/v1/ Email 規格）：
   - recipients 帶收件人 `name` 與每位收件人的合併變數 `variables`
   - `unsubscribedLink` 取消訂閱連結
   - 超過 100 位收件人（API 單次上限）時拋出明確錯誤
   - Events 事件查詢 API（送達/開信/點擊/退信等狀態）
7. **cc/bcc**：API 無此欄位，改為將 cc/bcc 地址併入 recipients 實際寄達
   （每人收到獨立信件，並以 address 去重）

## 變更內容

### 1. gemspec（`surenotify_rails.gemspec`）

- `required_ruby_version = ">= 3.0"`
- runtime 依賴只留 `actionmailer >= 6.0`（移除 `rest-client`、`json`）
- 開發依賴：`rspec ~> 3.13`、`webmock ~> 3.0`、`rake`
- 補 metadata：`homepage_uri`、`source_code_uri`、`rubygems_mfa_required`
- 移除已棄用的 `s.test_files`

### 2. `lib/surenotify_rails/client.rb`

- 改用 `Net::HTTP` 發送 POST JSON 到 `https://mail.surenotifyapi.com/v1/messages`
- headers 不變：`Content-Type: application/json`、`Accept: application/json`、`x-api-key`
- `verify_ssl: false` 對應 `OpenSSL::SSL::VERIFY_NONE`（預設驗證）
- `send_message` 回傳 `Net::HTTPResponse`
- 新增 `events(filters = {})`：GET `/v1/events`，
  支援 query 參數 `from` / `to` / `status` / `id` / `recipient`，
  回傳解析後的 JSON（Hash）；非 2xx 時拋出 `SurenotifyRails::APIError`

### 3. `lib/surenotify_rails/deliverer.rb`

- 成功判斷改為 `response.is_a?(Net::HTTPSuccess)`，內容改用 `response.body`
- 移除附件相關程式碼（連同 `lib/surenotify_rails/attachment.rb`）
- 訊息組裝：
  - `fromName` / `fromAddress`：取自 `from` 的 display name 與 address
  - `recipients`：合併 to + cc + bcc 的所有地址（以 address 去重），每位含：
    - `name`：mail 的 display name，無則以 address 的 @ 前段代替（API 標示必填）
    - `address`
    - `variables`：從 `message.surenotify_recipient_variables[address]` 取得（若有設定）
  - `subject`、`content`（HTML）
  - `unsubscribedLink`：取自 `message.surenotify_unsubscribed_link`，
    未設定則 fallback 到 `surenotify_settings[:unsubscribed_link]`（皆選填）
  - 空值移除（維持原行為）
- recipients 超過 100 位時拋出 `SurenotifyRails::TooManyRecipientsError`
  （附明確訊息說明 API 單次上限）

### 4. `lib/surenotify_rails/mail_ext.rb` 與錯誤類別

- 保留 `surenotify_recipient_variables`（實際使用於合併變數）
- 新增 `surenotify_unsubscribed_link` accessor
- 保留 `surenotify_variables` / `surenotify_options` / `surenotify_headers`
  （避免破壞現有使用者，但不再送出——mailgun 遺留欄位）
- 新增 `lib/surenotify_rails/errors.rb`：
  `Error < StandardError`、`TooManyRecipientsError < Error`、`APIError < Error`

### 5. 測試（`spec/`）

- 新增 `spec/lib/surenotify_rails/client_spec.rb`、`deliverer_spec.rb`
- 使用 RSpec 3 語法 + WebMock 攔截 HTTP 請求，驗證 URL、headers、JSON payload
- 涵蓋：基本寄送、display name、recipient variables、cc/bcc 併入與去重、
  unsubscribedLink（含 settings fallback）、101 位收件人拋錯、events 查詢
- `spec_helper.rb` 直接 require gem 本體，不再載入 dummy app
- 刪除 `spec/dummy/`、`spec/lib/mailgun_rails/`

### 6. CI（`.github/workflows/ci.yml`）

- matrix：
  - Rails 6.1 × Ruby 3.0、3.1
  - Rails 7.1 × Ruby 3.1、3.2、3.3
  - Rails 7.2 × Ruby 3.1、3.2、3.3
  - Rails 8.0 × Ruby 3.2、3.3、3.4
- `gemfiles/rails_61.gemfile`、`rails_71.gemfile`、`rails_72.gemfile`、`rails_80.gemfile`
- 刪除 `.travis.yml`、`.gemfiles/`

### 7. 其他清理

- `lib/surenotify_rails/version.rb` → `1.0.0`
- 刪除 repo 根目錄誤放的 `surenotify_rails-0.1.0.gem`，並加入 `.gitignore`（`*.gem`）
- README 更新：支援版本說明（Rails 6.1+ / Ruby 3.0+）、註明不支援附件與 cc/bcc
  （cc/bcc 會併入 recipients 個別寄送）、新功能用法範例
  （recipient variables、unsubscribedLink、events 查詢）
- `Rakefile` 更新為標準 RSpec task（`rake` 預設跑測試）

## 錯誤處理

- `Net::HTTP` 逾時或連線失敗會拋出標準例外（`Net::OpenTimeout` 等），
  由呼叫端（Action Mailer）處理，與原 rest-client 行為一致
- `deliver!`：API 回傳非 2xx 時不設定 message_id，直接回傳 response（維持原行為）
- 成功時 message_id 取回應 JSON 的 `id`（request id），維持原行為
- `Client#events`：非 2xx 拋出 `APIError`（含狀態碼與回應內容）
- recipients 超過 100 位：寄送前即拋出 `TooManyRecipientsError`，不打 API

## 不做的事（YAGNI）

- 不實作附件（API 文件明示不支援）
- 不自動分批超過 100 位的收件人（拋錯即可，由呼叫端決定怎麼分批）
- 不實作 Webhooks 管理與 Domains 驗證 API（非 Email 寄送核心）
- 不實作 mailgun 遺留的 variables/options/headers 轉換
  （`transform_surenotify_attributes_from_rails` 原本就被註解掉，將一併移除死程式碼；
  `mail_ext.rb` 的 attr_accessor 保留以免破壞現有使用者的呼叫）
- 不引入 rubocop 等額外工具

## 驗收標準

- `bundle exec rspec` 全綠（Ruby 3.x 本機）
- CI matrix 全部組合通過
- `gem build surenotify_rails.gemspec` 成功
