require "test_helper"

class ParserTest < ActiveSupport::TestCase
  RSS_BODY = <<~XML.freeze
    <?xml version="1.0"?>
    <rss version="2.0">
      <channel>
        <title>Example Feed</title>
        <item>
          <guid>entry-1</guid>
          <title>First</title>
          <link>https://example.com/1</link>
          <description>Summary one</description>
          <pubDate>Tue, 09 Jun 2026 12:00:00 GMT</pubDate>
        </item>
        <item>
          <title>No guid, link as identity</title>
          <link>https://example.com/2</link>
        </item>
      </channel>
    </rss>
  XML

  setup do
    @feed = Feed.create!(url: "https://example.com/feed.xml")
  end

  test "creates entries and updates the feed title" do
    new_entries = Feedbot::Feeds::Parser.upsert(@feed, RSS_BODY)

    assert_equal 2, new_entries.length
    assert_equal "Example Feed", @feed.reload.title

    first = @feed.entries.find_by!(guid: "entry-1")
    assert_equal "First", first.title
    assert_equal "Summary one", first.summary
    assert_equal Time.utc(2026, 6, 9, 12, 0), first.published_at
  end

  test "falls back to the entry URL when no guid is present" do
    Feedbot::Feeds::Parser.upsert(@feed, RSS_BODY)
    assert @feed.entries.exists?(guid: "https://example.com/2")
  end

  test "upsert is idempotent: re-parsing the same body creates nothing new" do
    Feedbot::Feeds::Parser.upsert(@feed, RSS_BODY)

    assert_no_difference -> { @feed.entries.count } do
      second_run = Feedbot::Feeds::Parser.upsert(@feed, RSS_BODY)
      assert_empty second_run
    end
  end
end
