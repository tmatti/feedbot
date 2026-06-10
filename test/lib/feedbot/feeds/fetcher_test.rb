require "test_helper"

class FetcherTest < ActiveSupport::TestCase
  setup do
    @feed = Feed.create!(url: "http://example.com/feed.xml")
  end

  test "returns body, caching headers, and canonical_url on 200" do
    stub_request(:get, "http://example.com/feed.xml").to_return(
      status: 200,
      body: "<rss/>",
      headers: { "ETag" => '"abc"', "Last-Modified" => "Wed, 10 Jun 2026 00:00:00 GMT" }
    )

    result = Feedbot::Feeds::Fetcher.fetch(@feed)

    assert_equal "<rss/>", result.body
    assert_equal '"abc"', result.etag
    assert_equal "Wed, 10 Jun 2026 00:00:00 GMT", result.last_modified
    assert_equal "http://example.com/feed.xml", result.canonical_url
    assert_not result.not_modified
  end

  test "follows redirects and reports the final URL as canonical_url" do
    stub_request(:get, "http://example.com/feed.xml")
      .to_return(status: 301, headers: { "Location" => "https://example.com/feed.xml" })
    stub_request(:get, "https://example.com/feed.xml")
      .to_return(status: 200, body: "<rss/>")

    result = Feedbot::Feeds::Fetcher.fetch(@feed)

    assert_equal "<rss/>", result.body
    assert_equal "https://example.com/feed.xml", result.canonical_url
  end

  test "returns not_modified on 304" do
    @feed.update!(etag: '"abc"', last_modified: "Wed, 10 Jun 2026 00:00:00 GMT")
    stub_request(:get, "http://example.com/feed.xml")
      .with(headers: { "If-None-Match" => '"abc"', "If-Modified-Since" => "Wed, 10 Jun 2026 00:00:00 GMT" })
      .to_return(status: 304)

    result = Feedbot::Feeds::Fetcher.fetch(@feed)
    assert result.not_modified
  end

  test "raises FetchError on HTTP error status" do
    stub_request(:get, "http://example.com/feed.xml").to_return(status: 500)

    error = assert_raises(Feedbot::Feeds::Fetcher::FetchError) do
      Feedbot::Feeds::Fetcher.fetch(@feed)
    end
    assert_equal "HTTP 500", error.message
  end

  test "raises FetchError when the redirect limit is exceeded" do
    stub_request(:get, "http://example.com/feed.xml")
      .to_return(status: 301, headers: { "Location" => "http://example.com/feed.xml" })

    assert_raises(Feedbot::Feeds::Fetcher::FetchError) do
      Feedbot::Feeds::Fetcher.fetch(@feed)
    end
  end
end
