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
end
