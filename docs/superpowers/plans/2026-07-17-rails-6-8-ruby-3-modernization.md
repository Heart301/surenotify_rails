# surenotify_rails 現代化（Rails 6/7/8、Ruby 3+）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓 surenotify_rails gem 支援 Rails 6.1–8.0 與 Ruby 3.0+，移除 rest-client 改用 Net::HTTP，並依 Surenotify API v1 實作收件人 name/variables、unsubscribedLink、100 位上限防呼與 Events 查詢。

**Architecture:** gem 是 Action Mailer 的 delivery method adapter：`Deliverer` 把 `Mail::Message` 轉成 Surenotify JSON payload，`Client` 用 Net::HTTP 打 `https://mail.surenotifyapi.com/v1`。測試用 RSpec 3 + WebMock 攔截 HTTP，不需要 Rails dummy app。

**Tech Stack:** Ruby 3+、actionmailer >= 6.0、Net::HTTP（內建）、RSpec 3、WebMock、GitHub Actions。

**Spec:** `docs/superpowers/specs/2026-07-17-rails-6-8-ruby-3-modernization-design.md`

## Global Constraints

- `required_ruby_version = ">= 3.0"`；runtime 依賴只有 `actionmailer >= 6.0`
- API base URL：`https://mail.surenotifyapi.com/v1`，headers：`Content-Type: application/json`、`Accept: application/json`、`x-api-key`
- 版本號 `1.0.0`
- 不支援附件、不自動分批、不實作 Webhooks/Domains API
- cc/bcc 併入 recipients（以 address 去重）
- 收件人上限 100，超過拋 `SurenotifyRails::TooManyRecipientsError`
- 所有 commit 訊息結尾加上 `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: 清理舊檔與基礎建設（gemspec / Gemfile / Rakefile / spec_helper）

**Files:**
- Delete: `.travis.yml`、`.gemfiles/`（整個目錄）、`surenotify_rails-0.1.0.gem`、`spec/dummy/`（整個目錄）、`spec/lib/mailgun_rails/`（整個目錄）、`lib/surenotify_rails/attachment.rb`、`README.rdoc`
- Modify: `surenotify_rails.gemspec`、`Gemfile`、`Rakefile`、`lib/surenotify_rails/version.rb`、`lib/surenotify_rails.rb`、`lib/surenotify_rails/mail_ext.rb`、`.gitignore`、`spec/spec_helper.rb`
- Create: `lib/surenotify_rails/errors.rb`

**Interfaces:**
- Produces: `SurenotifyRails::VERSION = "1.0.0"`；`SurenotifyRails::Error`、`SurenotifyRails::TooManyRecipientsError`、`SurenotifyRails::APIError`（有 `code`、`body` reader，建構式 `APIError.new(message, code:, body:)`）；`Mail::Message#surenotify_recipient_variables`、`#surenotify_unsubscribed_link` accessor；`spec/spec_helper.rb` 供所有 spec require
- 注意：此 task 完成後 `bundle exec rspec` 會因舊版 `client.rb` 還在 require `rest_client` 而無法載入——這是預期的，Task 2 重寫 client 後即恢復。此 task 驗證只到 `bundle install` 成功。

- [ ] **Step 1: 刪除過時檔案**

```bash
git rm -r .travis.yml .gemfiles spec/dummy spec/lib/mailgun_rails lib/surenotify_rails/attachment.rb README.rdoc
rm -f surenotify_rails-0.1.0.gem
```

- [ ] **Step 2: 重寫 gemspec**

`surenotify_rails.gemspec` 全檔改為：

```ruby
require_relative "lib/surenotify_rails/version"

Gem::Specification.new do |s|
  s.name        = "surenotify_rails"
  s.version     = SurenotifyRails::VERSION
  s.authors     = ["Leo Chen"]
  s.email       = ["pominx@gmail.com"]
  s.homepage    = "https://github.com/pominx/surenotify_rails"
  s.summary     = "Rails Action Mailer adapter for Surenotify (NewsLeopard)"
  s.description = "An adapter for using Surenotify with Rails and Action Mailer"
  s.license     = "MIT"

  s.metadata = {
    "homepage_uri"          => s.homepage,
    "source_code_uri"       => s.homepage,
    "rubygems_mfa_required" => "true"
  }

  s.required_ruby_version = ">= 3.0"

  s.files = Dir["lib/**/*", "MIT-LICENSE", "README.md"]

  s.add_dependency "actionmailer", ">= 6.0"

  s.add_development_dependency "rake"
  s.add_development_dependency "rspec", "~> 3.13"
  s.add_development_dependency "webmock", "~> 3.0"
end
```

- [ ] **Step 3: 重寫 Gemfile 與 Rakefile**

`Gemfile` 全檔改為：

```ruby
source "https://rubygems.org"

gemspec
```

`Rakefile` 全檔改為：

```ruby
require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task default: :spec
```

- [ ] **Step 4: 版本升為 1.0.0**

`lib/surenotify_rails/version.rb` 全檔改為：

```ruby
module SurenotifyRails
  VERSION = "1.0.0"
end
```

- [ ] **Step 5: 新增錯誤類別**

建立 `lib/surenotify_rails/errors.rb`：

```ruby
module SurenotifyRails
  class Error < StandardError; end

  class TooManyRecipientsError < Error; end

  class APIError < Error
    attr_reader :code, :body

    def initialize(message, code: nil, body: nil)
      super(message)
      @code = code
      @body = body
    end
  end
end
```

- [ ] **Step 6: 更新 mail_ext 與 gem 進入點**

`lib/surenotify_rails/mail_ext.rb` 全檔改為（保留 mailgun 遺留 accessor 避免破壞既有使用者，新增 `surenotify_unsubscribed_link`）：

```ruby
module Mail
  class Message
    attr_accessor :surenotify_variables
    attr_accessor :surenotify_options
    attr_accessor :surenotify_recipient_variables
    attr_accessor :surenotify_headers
    attr_accessor :surenotify_unsubscribed_link
  end
end
```

`lib/surenotify_rails.rb` 全檔改為（改用明確 require，取代 Dir glob）：

```ruby
require "action_mailer"
require "json"

require "surenotify_rails/version"
require "surenotify_rails/errors"
require "surenotify_rails/mail_ext"
require "surenotify_rails/client"
require "surenotify_rails/deliverer"

module SurenotifyRails
end
```

- [ ] **Step 7: 更新 .gitignore 與 spec_helper**

`.gitignore` 加入一行（若無同樣內容）：

```
*.gem
```

`spec/spec_helper.rb` 全檔改為：

```ruby
require "surenotify_rails"
require "webmock/rspec"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
```

- [ ] **Step 8: 驗證 bundle install**

Run: `bundle install`
Expected: 成功解析依賴（actionmailer >= 6.0、rspec 3.13.x、webmock），無 rest-client。

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "chore: modernize gem infrastructure for Rails 6-8 / Ruby 3+

- Require Ruby >= 3.0, actionmailer >= 6.0; drop rest-client and json deps
- Replace RSpec 2 / dummy app test setup with RSpec 3 + WebMock
- Remove stale mailgun specs, Rails 3-era dummy app, Travis CI, old gemfiles
- Remove broken attachment support (Surenotify API has no attachment field)
- Add error classes and surenotify_unsubscribed_link accessor
- Bump version to 1.0.0

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Client#send_message 改用 Net::HTTP

**Files:**
- Modify: `lib/surenotify_rails/client.rb`（全檔重寫）
- Create: `spec/lib/surenotify_rails/client_spec.rb`

**Interfaces:**
- Consumes: `SurenotifyRails::APIError`（Task 1）
- Produces: `Client.new(api_key, verify_ssl = true)`；`Client#send_message(options)` → 回傳 `Net::HTTPResponse`（POST `/v1/messages`，body 為 JSON）；`Client::API_URL = "https://mail.surenotifyapi.com/v1"`

- [ ] **Step 1: 寫失敗測試**

建立 `spec/lib/surenotify_rails/client_spec.rb`：

```ruby
require "spec_helper"

RSpec.describe SurenotifyRails::Client do
  subject(:client) { described_class.new("some-api-key") }

  describe "#send_message" do
    it "POSTs the JSON payload to the messages endpoint with API headers" do
      stub = stub_request(:post, "https://mail.surenotifyapi.com/v1/messages")
        .with(
          body: { subject: "hi" }.to_json,
          headers: {
            "Content-Type" => "application/json",
            "Accept"       => "application/json",
            "x-api-key"    => "some-api-key"
          }
        )
        .to_return(status: 200, body: { id: "req-1" }.to_json)

      response = client.send_message(subject: "hi")

      expect(stub).to have_been_requested
      expect(response).to be_a(Net::HTTPSuccess)
      expect(response.body).to eq({ id: "req-1" }.to_json)
    end
  end
end
```

- [ ] **Step 2: 執行測試確認失敗**

Run: `bundle exec rspec spec/lib/surenotify_rails/client_spec.rb`
Expected: FAIL——載入 `surenotify_rails` 時舊 `client.rb` 的 `require 'rest_client'` 拋 `LoadError`（rest-client 已從依賴移除）。

- [ ] **Step 3: 重寫 client.rb**

`lib/surenotify_rails/client.rb` 全檔改為：

```ruby
require "net/http"
require "json"

module SurenotifyRails
  class Client
    API_URL = "https://mail.surenotifyapi.com/v1".freeze

    attr_reader :api_key, :verify_ssl

    def initialize(api_key, verify_ssl = true)
      @api_key = api_key
      @verify_ssl = verify_ssl
    end

    def send_message(options)
      uri = URI("#{API_URL}/messages")
      request = Net::HTTP::Post.new(uri)
      apply_headers(request)
      request.body = JSON.dump(options)
      perform(uri, request)
    end

    private

    def apply_headers(request)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request["x-api-key"] = api_key
    end

    def perform(uri, request)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.verify_mode = verify_ssl ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
      http.request(request)
    end
  end
end
```

- [ ] **Step 4: 執行測試確認通過**

Run: `bundle exec rspec spec/lib/surenotify_rails/client_spec.rb`
Expected: PASS（1 example, 0 failures）。

- [ ] **Step 5: Commit**

```bash
git add lib/surenotify_rails/client.rb spec/lib/surenotify_rails/client_spec.rb
git commit -m "feat: replace rest-client with Net::HTTP in Client#send_message

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Client#events 事件查詢

**Files:**
- Modify: `lib/surenotify_rails/client.rb`
- Test: `spec/lib/surenotify_rails/client_spec.rb`

**Interfaces:**
- Consumes: `Client#apply_headers`、`Client#perform`（Task 2 的 private method）、`SurenotifyRails::APIError`（Task 1）
- Produces: `Client#events(filters = {})` → GET `/v1/events`（filters 轉 query string，支援 `from`/`to`/`status`/`id`/`recipient`），成功回傳 `JSON.parse` 後的 Hash，非 2xx 拋 `SurenotifyRails::APIError`

- [ ] **Step 1: 寫失敗測試**

在 `spec/lib/surenotify_rails/client_spec.rb` 的 `describe "#send_message"` 區塊後面加入：

```ruby
  describe "#events" do
    it "GETs events with query filters and returns parsed JSON" do
      stub_request(:get, "https://mail.surenotifyapi.com/v1/events")
        .with(
          query: { "status" => "open", "recipient" => "user@example.com" },
          headers: { "x-api-key" => "some-api-key" }
        )
        .to_return(status: 200, body: { items: [] }.to_json)

      result = client.events(status: "open", recipient: "user@example.com")

      expect(result).to eq("items" => [])
    end

    it "raises APIError when the API responds with an error" do
      stub_request(:get, "https://mail.surenotifyapi.com/v1/events")
        .to_return(status: 401, body: "unauthorized")

      expect { client.events }.to raise_error(SurenotifyRails::APIError) do |error|
        expect(error.code).to eq("401")
        expect(error.body).to eq("unauthorized")
      end
    end
  end
```

- [ ] **Step 2: 執行測試確認失敗**

Run: `bundle exec rspec spec/lib/surenotify_rails/client_spec.rb`
Expected: FAIL，`NoMethodError: undefined method 'events'`。

- [ ] **Step 3: 實作 events**

在 `lib/surenotify_rails/client.rb` 的 `send_message` 方法後、`private` 之前加入：

```ruby
    def events(filters = {})
      uri = URI("#{API_URL}/events")
      uri.query = URI.encode_www_form(filters) unless filters.empty?
      request = Net::HTTP::Get.new(uri)
      apply_headers(request)
      response = perform(uri, request)

      unless response.is_a?(Net::HTTPSuccess)
        raise APIError.new("Surenotify API error: #{response.code}",
                           code: response.code, body: response.body)
      end

      JSON.parse(response.body)
    end
```

- [ ] **Step 4: 執行測試確認通過**

Run: `bundle exec rspec spec/lib/surenotify_rails/client_spec.rb`
Expected: PASS（3 examples, 0 failures）。

- [ ] **Step 5: Commit**

```bash
git add lib/surenotify_rails/client.rb spec/lib/surenotify_rails/client_spec.rb
git commit -m "feat: add Client#events for querying message events

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Deliverer 基本寄送（recipients name/address、message_id）

**Files:**
- Modify: `lib/surenotify_rails/deliverer.rb`（全檔重寫）
- Create: `spec/lib/surenotify_rails/deliverer_spec.rb`

**Interfaces:**
- Consumes: `Client#send_message`（Task 2）、`Mail::Message#surenotify_*` accessor（Task 1）
- Produces: `Deliverer.new(settings)`（settings 為 Hash，鍵：`:api_key`、`:verify_ssl`、`:unsubscribed_link`）；`Deliverer#deliver!(rails_message)` → 成功（`Net::HTTPSuccess`）時把回應 JSON 的 `id` 寫入 `rails_message.message_id`，回傳 response。payload 欄位：`fromName`（display name，無則省略）、`fromAddress`、`recipients`（陣列，每項 `{name:, address:}`，name 無 display name 時用 address 的 @ 前段）、`subject`、`content`（HTML）。private method `build_surenotify_message_for`、`recipients_for`、`recipient_for`、`extract_html`、`remove_empty_values`、`surenotify_client` 供後續 task 擴充。

- [ ] **Step 1: 寫失敗測試**

建立 `spec/lib/surenotify_rails/deliverer_spec.rb`：

```ruby
require "spec_helper"

RSpec.describe SurenotifyRails::Deliverer do
  subject(:deliverer) { described_class.new(settings) }

  let(:settings) { { api_key: "some-api-key" } }
  let(:api_response) do
    { status: 200,
      body: { id: "request-id-1" }.to_json,
      headers: { "Content-Type" => "application/json" } }
  end

  def deliver_and_capture(message)
    captured = nil
    stub_request(:post, "https://mail.surenotifyapi.com/v1/messages")
      .with { |request| captured = JSON.parse(request.body); true }
      .to_return(api_response)
    deliverer.deliver!(message)
    captured
  end

  def build_message(from: "Sender Name <sender@example.com>",
                    to: "Receiver Name <receiver@example.com>")
    Mail.new do |m|
      m.from    from
      m.to      to
      m.subject "test subject"
      m.html_part do
        content_type "text/html; charset=UTF-8"
        body "<h1>Hello</h1>"
      end
    end
  end

  describe "#deliver!" do
    it "sends the basic payload fields to the messages endpoint" do
      payload = deliver_and_capture(build_message)

      expect(payload).to eq(
        "fromName"    => "Sender Name",
        "fromAddress" => "sender@example.com",
        "recipients"  => [{ "name" => "Receiver Name", "address" => "receiver@example.com" }],
        "subject"     => "test subject",
        "content"     => "<h1>Hello</h1>"
      )
    end

    it "omits fromName and falls back recipient name to the local part when no display name" do
      payload = deliver_and_capture(
        build_message(from: "sender@example.com", to: "receiver@example.com")
      )

      expect(payload).not_to have_key("fromName")
      expect(payload["recipients"]).to eq(
        [{ "name" => "receiver", "address" => "receiver@example.com" }]
      )
    end

    it "sets the rails message_id from the API response id" do
      message = build_message
      deliver_and_capture(message)

      expect(message.message_id).to eq("request-id-1")
    end

    it "does not set message_id and returns the response on API failure" do
      message = build_message
      stub_request(:post, "https://mail.surenotifyapi.com/v1/messages")
        .to_return(status: 400, body: "bad request")

      response = deliverer.deliver!(message)

      expect(response).not_to be_a(Net::HTTPSuccess)
      expect(response.code).to eq("400")
      expect(message.message_id).to be_nil
    end
  end
end
```

- [ ] **Step 2: 執行測試確認失敗**

Run: `bundle exec rspec spec/lib/surenotify_rails/deliverer_spec.rb`
Expected: FAIL——舊 deliverer 對 `Net::HTTPResponse` 呼叫 `response.code == 200`（新為字串）且 payload 欄位不符（如 recipients 缺 `name`）。

- [ ] **Step 3: 重寫 deliverer.rb**

`lib/surenotify_rails/deliverer.rb` 全檔改為：

```ruby
module SurenotifyRails
  class Deliverer
    attr_accessor :settings

    def initialize(settings)
      self.settings = settings
    end

    def api_key
      settings[:api_key]
    end

    def verify_ssl
      # default value = true
      settings[:verify_ssl] != false
    end

    def deliver!(rails_message)
      response = surenotify_client.send_message build_surenotify_message_for(rails_message)
      if response.is_a?(Net::HTTPSuccess)
        rails_message.message_id = JSON.parse(response.body)["id"]
      end
      response
    end

    private

    def build_surenotify_message_for(rails_message)
      from = rails_message[:from].addrs.first
      message = {
        fromName: from.display_name,
        fromAddress: from.address,
        recipients: recipients_for(rails_message),
        subject: rails_message.subject,
        content: extract_html(rails_message)
      }
      remove_empty_values(message)
    end

    def recipients_for(rails_message)
      rails_message[:to].addrs.map { |addr| recipient_for(addr) }
    end

    def recipient_for(addr)
      {
        name: addr.display_name || addr.address.split("@").first,
        address: addr.address
      }
    end

    # @see http://stackoverflow.com/questions/4868205/rails-mail-getting-the-body-as-plain-text
    def extract_html(rails_message)
      if rails_message.html_part
        rails_message.html_part.body.decoded
      else
        rails_message.content_type =~ /text\/html/ ? rails_message.body.decoded : nil
      end
    end

    def remove_empty_values(message)
      message.delete_if do |_key, value|
        value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end
    end

    def surenotify_client
      @surenotify_client ||= Client.new(api_key, verify_ssl)
    end
  end
end

ActionMailer::Base.add_delivery_method :surenotify, SurenotifyRails::Deliverer
```

- [ ] **Step 4: 執行測試確認通過**

Run: `bundle exec rspec spec/lib/surenotify_rails/deliverer_spec.rb`
Expected: PASS（4 examples, 0 failures）。

- [ ] **Step 5: 跑全部測試**

Run: `bundle exec rspec`
Expected: PASS（7 examples, 0 failures）。

- [ ] **Step 6: Commit**

```bash
git add lib/surenotify_rails/deliverer.rb spec/lib/surenotify_rails/deliverer_spec.rb
git commit -m "feat: rebuild Deliverer for Net::HTTP and Surenotify recipient schema

- Detect success via Net::HTTPSuccess instead of integer code
- Include required recipient name (display name or local part fallback)
- Remove broken attachment handling and dead mailgun transform code

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: cc/bcc 併入 recipients 並去重

**Files:**
- Modify: `lib/surenotify_rails/deliverer.rb`
- Test: `spec/lib/surenotify_rails/deliverer_spec.rb`

**Interfaces:**
- Consumes: `recipients_for` / `recipient_for`（Task 4）
- Produces: `recipients_for` 改為合併 to + cc + bcc 並以 address 去重（後續 task 繼續用同一 method）

- [ ] **Step 1: 寫失敗測試**

在 `deliverer_spec.rb` 的 `describe "#deliver!"` 區塊內加入：

```ruby
    it "merges cc and bcc addresses into recipients, deduplicated by address" do
      message = build_message
      message.cc  = "Copy Person <copy@example.com>"
      message.bcc = ["blind@example.com", "receiver@example.com"]

      payload = deliver_and_capture(message)

      expect(payload["recipients"]).to contain_exactly(
        { "name" => "Receiver Name", "address" => "receiver@example.com" },
        { "name" => "Copy Person",   "address" => "copy@example.com" },
        { "name" => "blind",         "address" => "blind@example.com" }
      )
    end
```

- [ ] **Step 2: 執行測試確認失敗**

Run: `bundle exec rspec spec/lib/surenotify_rails/deliverer_spec.rb`
Expected: FAIL——payload 只含 to 的一位收件人。

- [ ] **Step 3: 實作合併與去重**

`lib/surenotify_rails/deliverer.rb` 的 `recipients_for` 改為：

```ruby
    def recipients_for(rails_message)
      addrs = [:to, :cc, :bcc].flat_map do |field|
        rails_message[field] ? rails_message[field].addrs : []
      end
      addrs.uniq(&:address).map { |addr| recipient_for(addr) }
    end
```

- [ ] **Step 4: 執行測試確認通過**

Run: `bundle exec rspec spec/lib/surenotify_rails/deliverer_spec.rb`
Expected: PASS（5 examples, 0 failures）。

- [ ] **Step 5: Commit**

```bash
git add lib/surenotify_rails/deliverer.rb spec/lib/surenotify_rails/deliverer_spec.rb
git commit -m "feat: merge cc/bcc into recipients (Surenotify API has no cc/bcc)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: 每位收件人的合併變數（recipient variables）

**Files:**
- Modify: `lib/surenotify_rails/deliverer.rb`
- Test: `spec/lib/surenotify_rails/deliverer_spec.rb`

**Interfaces:**
- Consumes: `Mail::Message#surenotify_recipient_variables`（Task 1）、`recipient_for`（Task 4）
- Produces: `recipient_for(addr, rails_message)` 簽名改為兩個參數；recipients 項目多出選填 `variables` 欄位（來源：`surenotify_recipient_variables[address]`）

- [ ] **Step 1: 寫失敗測試**

在 `deliverer_spec.rb` 的 `describe "#deliver!"` 區塊內加入：

```ruby
    it "includes per-recipient variables from surenotify_recipient_variables" do
      message = build_message
      message.surenotify_recipient_variables = {
        "receiver@example.com" => { "coupon" => "ABC123" }
      }

      payload = deliver_and_capture(message)

      expect(payload["recipients"]).to eq(
        [{ "name"      => "Receiver Name",
           "address"   => "receiver@example.com",
           "variables" => { "coupon" => "ABC123" } }]
      )
    end
```

- [ ] **Step 2: 執行測試確認失敗**

Run: `bundle exec rspec spec/lib/surenotify_rails/deliverer_spec.rb`
Expected: FAIL——recipients 項目沒有 `variables` 欄位。

- [ ] **Step 3: 實作 variables**

`lib/surenotify_rails/deliverer.rb` 的 `recipients_for` 與 `recipient_for` 改為：

```ruby
    def recipients_for(rails_message)
      addrs = [:to, :cc, :bcc].flat_map do |field|
        rails_message[field] ? rails_message[field].addrs : []
      end
      addrs.uniq(&:address).map { |addr| recipient_for(addr, rails_message) }
    end

    def recipient_for(addr, rails_message)
      recipient = {
        name: addr.display_name || addr.address.split("@").first,
        address: addr.address
      }
      variables = (rails_message.surenotify_recipient_variables || {})[addr.address]
      recipient[:variables] = variables if variables
      recipient
    end
```

- [ ] **Step 4: 執行測試確認通過**

Run: `bundle exec rspec spec/lib/surenotify_rails/deliverer_spec.rb`
Expected: PASS（6 examples, 0 failures）。

- [ ] **Step 5: Commit**

```bash
git add lib/surenotify_rails/deliverer.rb spec/lib/surenotify_rails/deliverer_spec.rb
git commit -m "feat: support per-recipient merge variables

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: unsubscribedLink（per-message 與 settings fallback）

**Files:**
- Modify: `lib/surenotify_rails/deliverer.rb`
- Test: `spec/lib/surenotify_rails/deliverer_spec.rb`

**Interfaces:**
- Consumes: `Mail::Message#surenotify_unsubscribed_link`（Task 1）、`build_surenotify_message_for`（Task 4）
- Produces: payload 選填欄位 `unsubscribedLink`；優先序：message accessor > `settings[:unsubscribed_link]` > 省略

- [ ] **Step 1: 寫失敗測試**

在 `deliverer_spec.rb` 的 `describe "#deliver!"` 區塊內加入：

```ruby
    it "includes unsubscribedLink from the message accessor" do
      message = build_message
      message.surenotify_unsubscribed_link = "https://example.com/unsubscribe"

      payload = deliver_and_capture(message)

      expect(payload["unsubscribedLink"]).to eq("https://example.com/unsubscribe")
    end

    context "with an unsubscribed_link in settings" do
      let(:settings) do
        { api_key: "some-api-key", unsubscribed_link: "https://example.com/default-unsub" }
      end

      it "falls back to the settings value when the message does not set one" do
        payload = deliver_and_capture(build_message)

        expect(payload["unsubscribedLink"]).to eq("https://example.com/default-unsub")
      end
    end

    it "omits unsubscribedLink when neither message nor settings provide one" do
      payload = deliver_and_capture(build_message)

      expect(payload).not_to have_key("unsubscribedLink")
    end
```

- [ ] **Step 2: 執行測試確認失敗**

Run: `bundle exec rspec spec/lib/surenotify_rails/deliverer_spec.rb`
Expected: FAIL——前兩個新測試的 payload 沒有 `unsubscribedLink`（第三個會過，屬預期）。

- [ ] **Step 3: 實作 unsubscribedLink**

`lib/surenotify_rails/deliverer.rb` 的 `build_surenotify_message_for` 改為：

```ruby
    def build_surenotify_message_for(rails_message)
      from = rails_message[:from].addrs.first
      message = {
        fromName: from.display_name,
        fromAddress: from.address,
        recipients: recipients_for(rails_message),
        subject: rails_message.subject,
        content: extract_html(rails_message),
        unsubscribedLink: unsubscribed_link_for(rails_message)
      }
      remove_empty_values(message)
    end
```

並在 `recipient_for` 之後加入：

```ruby
    def unsubscribed_link_for(rails_message)
      rails_message.surenotify_unsubscribed_link || settings[:unsubscribed_link]
    end
```

- [ ] **Step 4: 執行測試確認通過**

Run: `bundle exec rspec spec/lib/surenotify_rails/deliverer_spec.rb`
Expected: PASS（9 examples, 0 failures）。

- [ ] **Step 5: Commit**

```bash
git add lib/surenotify_rails/deliverer.rb spec/lib/surenotify_rails/deliverer_spec.rb
git commit -m "feat: support unsubscribedLink via message accessor or settings

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: 超過 100 位收件人防呼

**Files:**
- Modify: `lib/surenotify_rails/deliverer.rb`
- Test: `spec/lib/surenotify_rails/deliverer_spec.rb`

**Interfaces:**
- Consumes: `SurenotifyRails::TooManyRecipientsError`（Task 1）、`recipients_for`（Task 6 版本）
- Produces: `Deliverer::MAX_RECIPIENTS = 100`；`deliver!` 在合併去重後超過 100 位時拋 `TooManyRecipientsError` 且不發出 HTTP 請求

- [ ] **Step 1: 寫失敗測試**

在 `deliverer_spec.rb` 的 `describe "#deliver!"` 區塊內加入：

```ruby
    it "raises TooManyRecipientsError before calling the API when over 100 recipients" do
      message = build_message(to: (1..101).map { |i| "user#{i}@example.com" })

      expect { deliverer.deliver!(message) }
        .to raise_error(SurenotifyRails::TooManyRecipientsError, /at most 100/)
      expect(a_request(:post, "https://mail.surenotifyapi.com/v1/messages"))
        .not_to have_been_made
    end
```

- [ ] **Step 2: 執行測試確認失敗**

Run: `bundle exec rspec spec/lib/surenotify_rails/deliverer_spec.rb`
Expected: FAIL——沒有拋錯，反而嘗試打 API（WebMock 回報 unstubbed request）。

- [ ] **Step 3: 實作上限檢查**

`lib/surenotify_rails/deliverer.rb` 的 class 開頭（`attr_accessor :settings` 之前）加入：

```ruby
    MAX_RECIPIENTS = 100
```

`recipients_for` 改為：

```ruby
    def recipients_for(rails_message)
      addrs = [:to, :cc, :bcc].flat_map do |field|
        rails_message[field] ? rails_message[field].addrs : []
      end
      recipients = addrs.uniq(&:address).map { |addr| recipient_for(addr, rails_message) }

      if recipients.size > MAX_RECIPIENTS
        raise TooManyRecipientsError,
              "Surenotify API allows at most #{MAX_RECIPIENTS} recipients per request " \
              "(got #{recipients.size})"
      end

      recipients
    end
```

- [ ] **Step 4: 執行測試確認通過**

Run: `bundle exec rspec`
Expected: PASS（13 examples, 0 failures）。

- [ ] **Step 5: Commit**

```bash
git add lib/surenotify_rails/deliverer.rb spec/lib/surenotify_rails/deliverer_spec.rb
git commit -m "feat: raise TooManyRecipientsError over the 100-recipient API limit

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: GitHub Actions CI 與版本矩陣 gemfiles

**Files:**
- Create: `.github/workflows/ci.yml`、`gemfiles/rails_61.gemfile`、`gemfiles/rails_71.gemfile`、`gemfiles/rails_72.gemfile`、`gemfiles/rails_80.gemfile`

**Interfaces:**
- Consumes: `bundle exec rspec`（整套測試，Task 1–8）
- Produces: CI matrix 驗證 Rails 6.1/7.1/7.2/8.0 × Ruby 3.0–3.4 相容性

- [ ] **Step 1: 建立 gemfiles**

`gemfiles/rails_61.gemfile`：

```ruby
source "https://rubygems.org"

gemspec path: ".."

gem "actionmailer", "~> 6.1.0"
# concurrent-ruby 1.3.4+ removed the logger require that ActiveSupport < 7.1 depends on
gem "concurrent-ruby", "< 1.3.4"
```

`gemfiles/rails_71.gemfile`：

```ruby
source "https://rubygems.org"

gemspec path: ".."

gem "actionmailer", "~> 7.1.0"
```

`gemfiles/rails_72.gemfile`：

```ruby
source "https://rubygems.org"

gemspec path: ".."

gem "actionmailer", "~> 7.2.0"
```

`gemfiles/rails_80.gemfile`：

```ruby
source "https://rubygems.org"

gemspec path: ".."

gem "actionmailer", "~> 8.0.0"
```

- [ ] **Step 2: 建立 CI workflow**

`.github/workflows/ci.yml`：

```yaml
name: CI

on:
  push:
    branches: [master]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        include:
          - { ruby: "3.0", gemfile: rails_61 }
          - { ruby: "3.1", gemfile: rails_61 }
          - { ruby: "3.1", gemfile: rails_71 }
          - { ruby: "3.2", gemfile: rails_71 }
          - { ruby: "3.3", gemfile: rails_71 }
          - { ruby: "3.1", gemfile: rails_72 }
          - { ruby: "3.2", gemfile: rails_72 }
          - { ruby: "3.3", gemfile: rails_72 }
          - { ruby: "3.2", gemfile: rails_80 }
          - { ruby: "3.3", gemfile: rails_80 }
          - { ruby: "3.4", gemfile: rails_80 }
    env:
      BUNDLE_GEMFILE: ${{ github.workspace }}/gemfiles/${{ matrix.gemfile }}.gemfile
    name: Ruby ${{ matrix.ruby }} / ${{ matrix.gemfile }}
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: ${{ matrix.ruby }}
          bundler-cache: true
      - run: bundle exec rspec
```

- [ ] **Step 3: 本地驗證一個矩陣組合**

Run: `BUNDLE_GEMFILE=gemfiles/rails_80.gemfile bundle install && BUNDLE_GEMFILE=gemfiles/rails_80.gemfile bundle exec rspec`
Expected: PASS（13 examples, 0 failures）。若本機 Ruby 版本不符 Rails 8 需求（>= 3.2），改測 `gemfiles/rails_71.gemfile`。

- [ ] **Step 4: 把 gemfiles lock 檔加入 .gitignore**

`.gitignore` 加入：

```
gemfiles/*.lock
```

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml gemfiles .gitignore
git commit -m "ci: add GitHub Actions matrix for Rails 6.1-8.0 x Ruby 3.0-3.4

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: README 更新與最終驗證

**Files:**
- Modify: `README.md`
- Verify: 全套測試 + `gem build`

**Interfaces:**
- Consumes: Task 1–9 的全部成果

- [ ] **Step 1: 重寫 README.md**

`README.md` 全檔改為：

````markdown
# surenotify_rails (電子豹非官方 Rails 套件)

*surenotify_rails* is an Action Mailer adapter for using 電子豹 [Surenotify](https://newsleopard.com/surenotify) in Rails apps. It uses the [Surenotify API v1](https://newsleopard.com/surenotify/api/v1/) internally.

## Requirements

- Ruby >= 3.0
- Rails (Action Mailer) >= 6.0 — tested against Rails 6.1, 7.1, 7.2 and 8.0

## Installing

In your `Gemfile`

```ruby
gem 'surenotify_rails'
```

## Usage

To configure your Surenotify credentials place the following code in the corresponding environment file (`development.rb`, `production.rb`...)

```ruby
config.action_mailer.delivery_method = :surenotify
config.action_mailer.surenotify_settings = {
  api_key: '<surenotify api key>',
  unsubscribed_link: 'https://example.com/unsubscribe' # optional default
}
```

Now you can send emails using plain Action Mailer:

```ruby
email = mail from: 'Your Name <sender@email.com>', to: 'receiver@email.com', subject: 'this is an email'
```

### Per-recipient merge variables

Set variables per recipient address (rendered by Surenotify templates, max 100 characters per value):

```ruby
def welcome_email
  message = mail from: 'sender@email.com', to: 'receiver@email.com', subject: 'welcome'
  message.surenotify_recipient_variables = {
    'receiver@email.com' => { 'name' => '小明', 'coupon' => 'ABC123' }
  }
  message
end
```

### Unsubscribe link

Override the default unsubscribe link per message:

```ruby
message.surenotify_unsubscribed_link = 'https://example.com/custom-unsubscribe'
```

### Querying message events

```ruby
client = SurenotifyRails::Client.new('<surenotify api key>')
client.events(status: 'open', recipient: 'receiver@email.com')
# => { "items" => [...] }
```

Raises `SurenotifyRails::APIError` on API errors. Events are limited to the past 30 days (max 50 results) by the API.

## Notes and limitations

- The Surenotify API allows at most **100 recipients per request**; `SurenotifyRails::TooManyRecipientsError` is raised beyond that (split batches yourself).
- The API has no cc/bcc concept: cc/bcc addresses are merged into `recipients` (deduplicated), so everyone receives an individual copy.
- Attachments are not supported by the Surenotify API.

Pull requests are welcomed
````

- [ ] **Step 2: 全套最終驗證**

Run: `bundle exec rspec && gem build surenotify_rails.gemspec`
Expected: 13 examples, 0 failures；`Successfully built RubyGem ... surenotify_rails-1.0.0.gem`。

Run: `rm -f surenotify_rails-1.0.0.gem`（build 產物不入版控）

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: update README for 1.0.0 (Rails 6-8, new features, limitations)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
