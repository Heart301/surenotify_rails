module SurenotifyRails
  class Deliverer
    MAX_RECIPIENTS = 100

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
        content: extract_html(rails_message),
        unsubscribedLink: unsubscribed_link_for(rails_message)
      }
      remove_empty_values(message)
    end

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

    def recipient_for(addr, rails_message)
      recipient = {
        name: addr.display_name || addr.address.split("@").first,
        address: addr.address
      }
      variables = (rails_message.surenotify_recipient_variables || {})[addr.address]
      recipient[:variables] = variables if variables
      recipient
    end

    def unsubscribed_link_for(rails_message)
      rails_message.surenotify_unsubscribed_link || settings[:unsubscribed_link]
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
