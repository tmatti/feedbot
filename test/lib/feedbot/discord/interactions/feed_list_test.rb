require "test_helper"

class FeedListTest < ActiveSupport::TestCase
  setup do
    @server = Server.create!(discord_id: 1111, name: "Test Server")
  end

  def create_subscriptions(count)
    count.times.map do |i|
      feed = Feed.create!(url: "https://example.com/feed#{i}.xml", title: "Feed #{i}")
      @server.subscriptions.create!(
        feed: feed, discord_channel_id: 2222, created_by_discord_user_id: 3333,
        mode: "realtime", created_at: i.minutes.ago
      )
    end
  end

  def list_interaction(page: nil)
    options = page ? [ { "name" => "page", "value" => page } ] : []
    {
      "type" => 2,
      "guild_id" => @server.discord_id.to_s,
      "data" => { "name" => "feed", "options" => [ { "name" => "list", "options" => options } ] }
    }
  end

  def embed_for(interaction)
    Feedbot::Discord::Interactions::FeedList.new(interaction).call[:data][:embeds].first
  end

  test "shows all subscriptions on one page when they fit" do
    create_subscriptions(3)
    embed = embed_for(list_interaction)

    assert_equal 3, embed[:fields].length
    assert_equal "3 subscriptions", embed[:footer][:text]
  end

  test "paginates beyond 10 subscriptions" do
    create_subscriptions(12)

    page1 = embed_for(list_interaction)
    assert_equal 10, page1[:fields].length
    assert_includes page1[:footer][:text], "Page 1 of 2"

    page2 = embed_for(list_interaction(page: 2))
    assert_equal 2, page2[:fields].length
    assert_includes page2[:footer][:text], "Page 2 of 2"

    assert_empty page1[:fields].map { |f| f[:name] } & page2[:fields].map { |f| f[:name] }
  end

  test "clamps out-of-range page numbers" do
    create_subscriptions(12)
    embed = embed_for(list_interaction(page: 99))
    assert_includes embed[:footer][:text], "Page 2 of 2"
  end

  test "returns a friendly message when there are no subscriptions" do
    response = Feedbot::Discord::Interactions::FeedList.new(list_interaction).call
    assert_includes response[:data][:content], "No active subscriptions"
  end
end
