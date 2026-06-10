require "test_helper"

class DispatcherTest < ActiveSupport::TestCase
  setup do
    @dispatcher = Feedbot::Discord::Interactions::Dispatcher.new
    @server = Server.create!(discord_id: 1111, name: "Test Server")

    @rails_feed = Feed.create!(url: "https://rubyonrails.org/feed.xml", title: "Riding Rails")
    @hn_feed    = Feed.create!(url: "https://news.ycombinator.com/rss", title: "Hacker News")

    @rails_sub = @server.subscriptions.create!(
      feed: @rails_feed, discord_channel_id: 2222, created_by_discord_user_id: 3333, mode: "realtime"
    )
    @hn_sub = @server.subscriptions.create!(
      feed: @hn_feed, discord_channel_id: 2222, created_by_discord_user_id: 3333, mode: "realtime"
    )
  end

  def autocomplete_interaction(subcommand, typed)
    {
      "type" => 4,
      "guild_id" => @server.discord_id.to_s,
      "data" => {
        "name" => "feed",
        "options" => [
          {
            "name" => subcommand,
            "options" => [ { "name" => "id", "value" => typed, "focused" => true } ]
          }
        ]
      }
    }
  end

  test "responds to PING with PONG" do
    assert_equal({ type: 1 }, @dispatcher.call({ "type" => 1 }))
  end

  test "routes list command" do
    interaction = {
      "type" => 2,
      "guild_id" => @server.discord_id.to_s,
      "data" => { "name" => "feed", "options" => [ { "name" => "list" } ] }
    }
    response = @dispatcher.call(interaction)
    assert_equal 4, response[:type]
  end

  test "routes remove command" do
    interaction = {
      "type" => 2,
      "guild_id" => @server.discord_id.to_s,
      "data" => {
        "name" => "feed",
        "options" => [ { "name" => "remove", "options" => [ { "name" => "id", "value" => @hn_sub.id.to_s } ] } ]
      }
    }
    response = @dispatcher.call(interaction)
    assert_includes response[:data][:content], "Hacker News"
    assert_not Subscription.exists?(@hn_sub.id)
  end

  test "remove autocomplete returns matching subscriptions" do
    response = @dispatcher.call(autocomplete_interaction("remove", "rails"))

    assert_equal 8, response[:type]
    assert_equal [ { name: "Riding Rails", value: @rails_sub.id.to_s } ], response[:data][:choices]
  end

  test "edit autocomplete returns choices instead of nil" do
    response = @dispatcher.call(autocomplete_interaction("edit", ""))

    assert_equal 8, response[:type]
    assert_equal 2, response[:data][:choices].length
  end

  test "autocomplete filters by feed URL too" do
    response = @dispatcher.call(autocomplete_interaction("edit", "ycombinator"))

    assert_equal [ { name: "Hacker News", value: @hn_sub.id.to_s } ], response[:data][:choices]
  end

  test "autocomplete returns no choices for an unknown guild" do
    interaction = autocomplete_interaction("remove", "")
    interaction["guild_id"] = "999999"

    response = @dispatcher.call(interaction)
    assert_equal [], response[:data][:choices]
  end
end
