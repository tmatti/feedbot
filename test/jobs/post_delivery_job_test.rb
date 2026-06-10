require "test_helper"

class PostDeliveryJobTest < ActiveJob::TestCase
  setup do
    ENV["DISCORD_APP_ID"]    ||= "test-app-id"
    ENV["DISCORD_BOT_TOKEN"] ||= "test-bot-token"

    @server = Server.create!(discord_id: 1111, name: "Test Server")
    @feed   = Feed.create!(url: "https://example.com/feed.xml", title: "Example Feed")
    @sub = @server.subscriptions.create!(
      feed: @feed, discord_channel_id: 2222, created_by_discord_user_id: 3333, mode: "realtime"
    )
    @entry = @feed.entries.create!(guid: "g1", title: "Hello", url: "https://example.com/1", published_at: Time.current)
    @messages_url = "https://discord.com/api/v10/channels/#{@sub.discord_channel_id}/messages"
  end

  test "posts the embed and records the delivery" do
    stub_request(:post, @messages_url)
      .to_return(status: 200, body: { id: "98765" }.to_json, headers: { "Content-Type" => "application/json" })

    PostDeliveryJob.perform_now(@sub.id, @entry.id)

    delivery = Delivery.find_by!(subscription: @sub, entry: @entry)
    assert_equal 98765, delivery.discord_message_id
    assert_not_nil delivery.posted_at
  end

  test "skips posting when a non-skipped delivery already exists" do
    Delivery.create!(subscription: @sub, entry: @entry, posted_at: Time.current)

    PostDeliveryJob.perform_now(@sub.id, @entry.id)

    assert_not_requested :post, @messages_url
    assert_equal 1, Delivery.where(subscription: @sub, entry: @entry).count
  end

  test "treats a concurrent duplicate insert as success" do
    stub_request(:post, @messages_url)
      .to_return(status: 200, body: { id: "98765" }.to_json, headers: { "Content-Type" => "application/json" })

    # A skipped row passes the `exists?(skipped: false)` guard but still
    # collides on the (subscription_id, entry_id) unique index, exercising
    # the same conflict path as a concurrent insert.
    Delivery.create!(subscription: @sub, entry: @entry, skipped: true)

    assert_nothing_raised { PostDeliveryJob.perform_now(@sub.id, @entry.id) }

    assert_equal 1, Delivery.where(subscription: @sub, entry: @entry).count
  end

  test "reschedules with a relative wait on rate limit" do
    stub_request(:post, @messages_url)
      .to_return(status: 429, body: { retry_after: 2.5 }.to_json, headers: { "Content-Type" => "application/json" })

    freeze_time do
      PostDeliveryJob.perform_now(@sub.id, @entry.id)

      job = enqueued_jobs.find { |j| j["job_class"] == "PostDeliveryJob" }
      assert job, "expected PostDeliveryJob to be re-enqueued"
      assert_in_delta 2.5.seconds.from_now.to_f, job[:at], 0.01
    end

    assert_nil Delivery.find_by(subscription: @sub, entry: @entry)
  end

  test "disables the subscription on unknown channel" do
    stub_request(:post, @messages_url)
      .to_return(status: 404, body: { code: 10003, message: "Unknown Channel" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    PostDeliveryJob.perform_now(@sub.id, @entry.id)
    assert_equal "disabled", @sub.reload.status
  end

  test "records an error ledger row on other Discord errors" do
    stub_request(:post, @messages_url)
      .to_return(status: 400, body: { code: 50035, message: "Invalid Form Body" }.to_json,
                 headers: { "Content-Type" => "application/json" })

    PostDeliveryJob.perform_now(@sub.id, @entry.id)

    delivery = Delivery.find_by!(subscription: @sub, entry: @entry)
    assert_equal "Invalid Form Body", delivery.error
    assert_nil delivery.posted_at
    assert_equal "active", @sub.reload.status
  end
end
