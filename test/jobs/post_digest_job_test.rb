require "test_helper"

class PostDigestJobTest < ActiveJob::TestCase
  setup do
    ENV["DISCORD_APP_ID"]    ||= "test-app-id"
    ENV["DISCORD_BOT_TOKEN"] ||= "test-bot-token"

    @server = Server.create!(discord_id: 1111, name: "Test Server")
    @feed   = Feed.create!(url: "https://example.com/feed.xml", title: "Example Feed")
    @sub = @server.subscriptions.create!(
      feed: @feed, discord_channel_id: 2222, created_by_discord_user_id: 3333,
      mode: "digest", schedule_kind: "daily"
    )
    @messages_url = "https://discord.com/api/v10/channels/#{@sub.discord_channel_id}/messages"
  end

  def create_entries(count)
    count.times.map do |i|
      @feed.entries.create!(guid: "g#{i}", title: "Entry #{i}", published_at: i.hours.ago)
    end
  end

  test "chunks entries into messages of at most 10 embeds" do
    entries = create_entries(12)
    stub = stub_request(:post, @messages_url)
      .to_return(status: 200, body: { id: "1" }.to_json, headers: { "Content-Type" => "application/json" })

    PostDigestJob.perform_now(@sub.id, entries.map(&:id))

    assert_requested stub, times: 2
    assert_equal 12, Delivery.where(subscription: @sub).where.not(posted_at: nil).count
  end

  test "records error ledger rows and stops on unknown channel" do
    entries = create_entries(3)
    stub_request(:post, @messages_url)
      .to_return(status: 404, body: { code: 10003, message: "Unknown Channel" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    PostDigestJob.perform_now(@sub.id, entries.map(&:id))

    assert_equal 3, Delivery.where(subscription: @sub).where.not(error: nil).count
  end

  test "gives up after bounded rate-limit retries" do
    entries = create_entries(1)
    stub = stub_request(:post, @messages_url)
      .to_return(status: 429, body: { retry_after: 0 }.to_json, headers: { "Content-Type" => "application/json" })

    assert_raises(Feedbot::Discord::RestClient::RateLimitError) do
      PostDigestJob.perform_now(@sub.id, entries.map(&:id))
    end

    assert_requested stub, times: 6
  end
end
