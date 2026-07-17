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
