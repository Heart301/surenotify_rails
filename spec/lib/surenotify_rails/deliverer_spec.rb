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
      m.to      to if to
      m.subject "test subject"
      m.html_part do
        content_type "text/html; charset=UTF-8"
        body "<h1>Hello</h1>"
      end
    end
  end

  def build_html_message(from: "Sender Name <sender@example.com>",
                         to: "Receiver Name <receiver@example.com>",
                         body: "<h1>Direct HTML</h1>")
    Mail.new do |m|
      m.from         from
      m.to           to
      m.subject      "test subject"
      m.content_type "text/html; charset=UTF-8"
      m.body         body
    end
  end

  def build_plain_text_message(from: "Sender Name <sender@example.com>",
                               to: "Receiver Name <receiver@example.com>",
                               body: "Plain text body")
    Mail.new do |m|
      m.from    from
      m.to      to
      m.subject "test subject"
      m.body    body
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

    it "raises APIError and does not set message_id on API failure" do
      message = build_message
      stub_request(:post, "https://mail.surenotifyapi.com/v1/messages")
        .to_return(status: 400, body: "bad request")

      expect { deliverer.deliver!(message) }
        .to raise_error(SurenotifyRails::APIError) do |error|
          expect(error.code).to eq("400")
          expect(error.body).to eq("bad request")
        end
      expect(message.message_id).to be_nil
    end

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

    it "raises TooManyRecipientsError before calling the API when over 100 recipients" do
      message = build_message(to: (1..101).map { |i| "user#{i}@example.com" })

      expect { deliverer.deliver!(message) }
        .to raise_error(SurenotifyRails::TooManyRecipientsError, /at most 100/)
      expect(a_request(:post, "https://mail.surenotifyapi.com/v1/messages"))
        .not_to have_been_made
    end

    it "raises NoRecipientsError before calling the API when to/cc/bcc are all empty" do
      message = build_message(to: nil)

      expect { deliverer.deliver!(message) }
        .to raise_error(SurenotifyRails::NoRecipientsError, /no recipients/)
      expect(a_request(:post, "https://mail.surenotifyapi.com/v1/messages"))
        .not_to have_been_made
    end

    it "passes exactly 100 recipients without raising" do
      message = build_message(to: (1..100).map { |i| "user#{i}@example.com" })

      payload = deliver_and_capture(message)

      expect(payload["recipients"].size).to eq(100)
      expect(a_request(:post, "https://mail.surenotifyapi.com/v1/messages"))
        .to have_been_made
    end

    it "uses the body directly as content for a non-multipart HTML message" do
      payload = deliver_and_capture(build_html_message(body: "<h1>Direct HTML</h1>"))

      expect(payload["content"]).to eq("<h1>Direct HTML</h1>")
    end

    it "omits the content key for a plain-text-only message" do
      payload = deliver_and_capture(build_plain_text_message(body: "Plain text body"))

      expect(payload).not_to have_key("content")
    end

    it "passes verify_ssl: false from settings through to the Surenotify client" do
      settings = { api_key: "some-api-key", verify_ssl: false }
      deliverer = described_class.new(settings)

      expect(deliverer.send(:surenotify_client).verify_ssl).to eq(false)
    end
  end
end
