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
- `deliver!` raises `SurenotifyRails::APIError` (with `code` and `body`) when the API rejects the request; it no longer silently returns the failed response.

Pull requests are welcomed

