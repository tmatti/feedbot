require "test_helper"

class PollFeedJobTest < ActiveJob::TestCase
  RSS_BODY = <<~XML.freeze
    <?xml version="1.0"?>
    <rss version="2.0">
      <channel>
        <title>Example Feed</title>
        <item>
          <guid>entry-1</guid>
          <title>Hello</title>
          <link>https://example.com/1</link>
          <pubDate>Tue, 09 Jun 2026 12:00:00 GMT</pubDate>
        </item>
      </channel>
    </rss>
  XML

  setup do
    @feed   = Feed.create!(url: "https://example.com/feed.xml")
    @server = Server.create!(discord_id: 1111, name: "Test Server")
    @sub = @server.subscriptions.create!(
      feed: @feed, discord_channel_id: 2222, created_by_discord_user_id: 3333, mode: "realtime"
    )
  end

  test "creates entries and enqueues realtime deliveries on success" do
    stub_request(:get, @feed.url).to_return(status: 200, body: RSS_BODY)

    PollFeedJob.perform_now(@feed.id)

    entry = @feed.entries.find_by!(guid: "entry-1")
    assert_enqueued_with(job: PostDeliveryJob, args: [ @sub.id, entry.id ])
    assert_equal 0, @feed.reload.consecutive_failures
    assert_equal "Example Feed", @feed.title
  end

  test "does not enqueue deliveries for entries that already exist" do
    @feed.entries.create!(guid: "entry-1", title: "Hello", published_at: Time.current)
    stub_request(:get, @feed.url).to_return(status: 200, body: RSS_BODY)

    assert_no_enqueued_jobs(only: PostDeliveryJob) do
      PollFeedJob.perform_now(@feed.id)
    end
  end

  test "notes exactly one failure on HTTP error and does not raise" do
    stub_request(:get, @feed.url).to_return(status: 500)

    assert_nothing_raised { PollFeedJob.perform_now(@feed.id) }
    assert_equal 1, @feed.reload.consecutive_failures
    assert_equal "HTTP 500", @feed.last_error
  end

  test "notes exactly one failure on parse error and does not raise for retry" do
    stub_request(:get, @feed.url).to_return(status: 200, body: "this is not a feed")

    assert_nothing_raised { PollFeedJob.perform_now(@feed.id) }
    assert_equal 1, @feed.reload.consecutive_failures
  end

  test "refreshes poll bookkeeping on 304 not modified" do
    @feed.update!(etag: '"abc"')
    stub_request(:get, @feed.url).to_return(status: 304)

    freeze_time do
      PollFeedJob.perform_now(@feed.id)
      assert_equal 15.minutes.from_now, @feed.reload.next_poll_at
    end
  end

  test "skips disabled feeds" do
    @feed.update!(status: "disabled")

    PollFeedJob.perform_now(@feed.id)
    assert_not_requested :get, @feed.url
  end
end
