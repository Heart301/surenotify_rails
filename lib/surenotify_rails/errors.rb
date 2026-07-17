module SurenotifyRails
  class Error < StandardError; end

  class TooManyRecipientsError < Error; end

  class NoRecipientsError < Error; end

  class APIError < Error
    attr_reader :code, :body

    def initialize(message, code: nil, body: nil)
      super(message)
      @code = code
      @body = body
    end
  end
end
