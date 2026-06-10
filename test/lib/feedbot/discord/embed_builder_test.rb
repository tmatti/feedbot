require "test_helper"

class EmbedBuilderTest < ActiveSupport::TestCase
  setup do
    @feed = Feed.create!(url: "https://example.com/feed.xml", title: "Example Feed")
  end

  test "builds the PRD embed shape" do
    entry = @feed.entries.create!(
      guid: "g1",
      title: "Hello World",
      url: "https://example.com/1",
      summary: "<p>Some <b>html</b> summary</p>",
      image_url: "https://example.com/img.png",
      published_at: Time.utc(2026, 6, 9, 12, 0)
    )

    embed = Feedbot::Discord::EmbedBuilder.build(entry, @feed)

    assert_equal "Hello World", embed[:title]
    assert_equal "https://example.com/1", embed[:url]
    assert_equal "Some html summary", embed[:description]
    assert_equal({ name: "Example Feed" }, embed[:author])
    assert_equal "2026-06-09T12:00:00Z", embed[:timestamp]
    assert_equal({ url: "https://example.com/img.png" }, embed[:thumbnail])
    assert_equal 0x5865F2, embed[:color]
  end

  test "omits nil fields and thumbnail when absent" do
    entry = @feed.entries.create!(guid: "g2")

    embed = Feedbot::Discord::EmbedBuilder.build(entry, @feed)

    assert_not embed.key?(:title)
    assert_not embed.key?(:description)
    assert_not embed.key?(:thumbnail)
    assert_not embed.key?(:timestamp)
  end

  test "truncates long titles to Discord limits" do
    entry = @feed.entries.create!(guid: "g3", title: "x" * 500)
    embed = Feedbot::Discord::EmbedBuilder.build(entry, @feed)
    assert embed[:title].length <= 256
  end
end
