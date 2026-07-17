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
