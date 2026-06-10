require "test_helper"

class FeedTest < ActiveSupport::TestCase
  setup do
    @feed = Feed.create!(url: "https://example.com/feed.xml")
  end

  test "note_failure! walks the 5/15/60/240 minute backoff and then plateaus" do
    expected_backoffs = [ 5, 15, 60, 240, 240 ]

    freeze_time do
      expected_backoffs.each_with_index do |minutes, i|
        @feed.note_failure!("boom")
        assert_equal i + 1, @feed.consecutive_failures
        assert_equal minutes.minutes.from_now, @feed.next_poll_at
      end
    end
  end

  test "note_failure! records the error and stays active below 20 failures" do
    @feed.note_failure!("HTTP 500")
    assert_equal "HTTP 500", @feed.last_error
    assert_equal "active", @feed.status
  end

  test "note_failure! disables the feed at 20 consecutive failures" do
    @feed.update!(consecutive_failures: 19)
    @feed.note_failure!("boom")
    assert_equal 20, @feed.consecutive_failures
    assert_equal "disabled", @feed.status
  end

  test "note_success! resets failure state and schedules the next poll" do
    @feed.update!(consecutive_failures: 5, last_error: "boom")

    freeze_time do
      @feed.note_success!(etag: '"abc"', last_modified: "lm", canonical_url: "https://example.com/feed.xml")
      assert_equal 0, @feed.consecutive_failures
      assert_nil @feed.last_error
      assert_equal 15.minutes.from_now, @feed.next_poll_at
      assert_equal '"abc"', @feed.etag
    end
  end

  test "note_success! keeps existing caching headers when none are passed" do
    @feed.update!(etag: '"abc"', last_modified: "lm", canonical_url: "https://c.example.com")
    @feed.note_success!
    assert_equal '"abc"', @feed.etag
    assert_equal "lm", @feed.last_modified
    assert_equal "https://c.example.com", @feed.canonical_url
  end
end
