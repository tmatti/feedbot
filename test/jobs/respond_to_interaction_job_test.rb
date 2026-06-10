require "test_helper"

class RespondToInteractionJobTest < ActiveJob::TestCase
  RSS_BODY = <<~XML.freeze
    <?xml version="1.0"?>
    <rss version="2.0">
      <channel>
        <title>Example Feed</title>
        <item>
          <guid>old-entry</guid>
          <title>Old</title>
          <link>https://example.com/old</link>
          <pubDate>Mon, 01 Jun 2026 12:00:00 GMT</pubDate>
        </item>
        <item>
          <guid>latest-entry</guid>
          <title>Latest</title>
          <link>https://example.com/latest</link>
          <pubDate>Tue, 09 Jun 2026 12:00:00 GMT</pubDate>
        </item>
      </channel>
    </rss>
  XML

  setup do
    ENV["DISCORD_APP_ID"]    ||= "test-app-id"
    ENV["DISCORD_BOT_TOKEN"] ||= "test-bot-token"

    @feed_url = "https://example.com/feed.xml"
    stub_request(:get, @feed_url).to_return(status: 200, body: RSS_BODY)
    @patch_stub = stub_request(:patch, %r{https://discord\.com/api/v10/webhooks/.+/messages/@original})
      .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
  end

  def perform_add(mode:, schedule_kind: nil, schedule_time: nil)
    RespondToInteractionJob.perform_now(
      interaction_token: "tok123",
      guild_id: 1111,
      channel_id: 2222,
      user_id: 3333,
      url: @feed_url,
      mode: mode,
      schedule_kind: schedule_kind,
      schedule_time: schedule_time
    )
  end

  test "creates a digest subscription with a computed next_run_at" do
    perform_add(mode: "digest", schedule_kind: "daily", schedule_time: "09:00")

    sub = Subscription.sole
    assert_equal "digest", sub.mode
    assert_equal "0 9 * * * Etc/UTC", sub.schedule_cron
    assert_not_nil sub.next_run_at

    assert_requested @patch_stub
  end

  test "posts only the latest entry and marks the rest skipped" do
    perform_add(mode: "realtime")

    sub = Subscription.sole
    latest = Entry.find_by!(guid: "latest-entry")
    old    = Entry.find_by!(guid: "old-entry")

    assert_not Delivery.find_by!(subscription: sub, entry: latest).skipped
    assert Delivery.find_by!(subscription: sub, entry: old).skipped
  end

  test "reports fetch failures to the user instead of raising" do
    stub_request(:get, @feed_url).to_return(status: 500)

    assert_nothing_raised { perform_add(mode: "realtime") }

    assert_equal 0, Subscription.count
    assert_requested :patch, %r{webhooks/.+/messages/@original},
      body: /Failed to fetch feed/
  end
end
