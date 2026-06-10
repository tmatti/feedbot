require "test_helper"

class FeedConfigTest < ActiveSupport::TestCase
  def config_interaction(guild_id, tz)
    {
      "type" => 2,
      "guild_id" => guild_id.to_s,
      "data" => {
        "name" => "feed",
        "options" => [
          {
            "name" => "config",
            "options" => [
              { "name" => "timezone", "options" => [ { "name" => "tz", "value" => tz } ] }
            ]
          }
        ]
      }
    }
  end

  test "sets a valid IANA timezone and recomputes digest schedules" do
    server = Server.create!(discord_id: 1111, name: "Test Server", timezone: "UTC")
    feed   = Feed.create!(url: "https://example.com/feed.xml")
    sub = server.subscriptions.create!(
      feed: feed, discord_channel_id: 2222, created_by_discord_user_id: 3333,
      mode: "digest", schedule_kind: "daily", schedule_time: "09:00"
    )

    response = Feedbot::Discord::Interactions::FeedConfig.new(
      config_interaction(server.discord_id, "America/New_York")
    ).call

    assert_includes response[:data][:content], "America/New_York"
    assert_equal "America/New_York", server.reload.timezone
    assert_equal "0 9 * * * America/New_York", sub.reload.schedule_cron
    assert_not_nil sub.next_run_at
  end

  test "rejects an unknown timezone" do
    response = Feedbot::Discord::Interactions::FeedConfig.new(
      config_interaction(1111, "Mars/Olympus_Mons")
    ).call

    assert_includes response[:data][:content], "Unknown timezone"
    assert_nil Server.find_by(discord_id: 1111)
  end

  test "creates the server record on first config" do
    response = Feedbot::Discord::Interactions::FeedConfig.new(
      config_interaction(5555, "Europe/Berlin")
    ).call

    assert_includes response[:data][:content], "Europe/Berlin"
    assert_equal "Europe/Berlin", Server.find_by(discord_id: 5555).timezone
  end
end
