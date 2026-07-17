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
