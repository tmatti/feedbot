require "test_helper"

class SubscriptionTest < ActiveSupport::TestCase
  setup do
    @server = Server.create!(discord_id: 1111, name: "Test Server", timezone: "UTC")
    @feed   = Feed.create!(url: "https://example.com/feed.xml")
  end

  def build_subscription(mode: "digest", schedule_kind: "daily", schedule_time: nil, timezone: nil)
    @server.update!(timezone: timezone) if timezone
    @server.subscriptions.create!(
      feed: @feed,
      discord_channel_id: 2222,
      created_by_discord_user_id: 3333,
      mode: mode,
      schedule_kind: schedule_kind,
      schedule_time: schedule_time
    )
  end

  test "derived_cron is nil for realtime subscriptions" do
    sub = build_subscription(mode: "realtime", schedule_kind: nil)
    assert_nil sub.derived_cron
  end

  test "derived_cron maps fixed kinds and appends the server timezone" do
    sub = build_subscription(schedule_kind: "hourly")
    assert_equal "0 * * * * Etc/UTC", sub.derived_cron
  end

  test "derived_cron uses schedule_time for daily" do
    sub = build_subscription(schedule_kind: "daily", schedule_time: "18:30", timezone: "America/New_York")
    assert_equal "30 18 * * * America/New_York", sub.derived_cron
  end

  test "derived_cron defaults at: to 09:00" do
    sub = build_subscription(schedule_kind: "daily", schedule_time: nil)
    assert_equal "0 9 * * * Etc/UTC", sub.derived_cron
  end

  test "derived_cron uses weekday 1 for weekly" do
    sub = build_subscription(schedule_kind: "weekly", schedule_time: "07:15")
    assert_equal "15 7 * * 1 Etc/UTC", sub.derived_cron
  end

  test "derived_cron resolves ActiveSupport timezone aliases to IANA names" do
    sub = build_subscription(schedule_kind: "daily", timezone: "Eastern Time (US & Canada)")
    assert_equal "0 9 * * * America/New_York", sub.derived_cron
  end

  test "compute_next_run_at! sets schedule_cron and next_run_at" do
    sub = build_subscription(schedule_kind: "daily", schedule_time: "09:00", timezone: "America/New_York")

    travel_to Time.utc(2026, 6, 10, 0, 0) do
      sub.compute_next_run_at!
    end

    assert_equal "0 9 * * * America/New_York", sub.schedule_cron
    # 09:00 EDT == 13:00 UTC
    assert_equal Time.utc(2026, 6, 10, 13, 0), sub.next_run_at
  end

  test "compute_next_run_at! is DST-correct across the spring-forward transition" do
    sub = build_subscription(schedule_kind: "daily", schedule_time: "09:00", timezone: "America/New_York")

    # 2026-03-07 is the day before US DST begins; 09:00 EST == 14:00 UTC
    travel_to Time.utc(2026, 3, 6, 20, 0) do
      sub.compute_next_run_at!
    end
    assert_equal Time.utc(2026, 3, 7, 14, 0), sub.next_run_at

    # After 2026-03-08 spring-forward, 09:00 EDT == 13:00 UTC
    travel_to Time.utc(2026, 3, 8, 20, 0) do
      sub.compute_next_run_at!
    end
    assert_equal Time.utc(2026, 3, 9, 13, 0), sub.next_run_at
  end

  test "compute_next_run_at! is a no-op for realtime subscriptions" do
    sub = build_subscription(mode: "realtime", schedule_kind: nil)
    sub.compute_next_run_at!
    assert_nil sub.next_run_at
    assert_nil sub.schedule_cron
  end

  test "due_digests includes only active digest subs whose next_run_at has passed" do
    due = build_subscription(schedule_kind: "hourly")
    due.update!(next_run_at: 1.minute.ago)

    feed2 = Feed.create!(url: "https://example.com/feed2.xml")
    not_due = @server.subscriptions.create!(
      feed: feed2, discord_channel_id: 2222, created_by_discord_user_id: 3333,
      mode: "digest", schedule_kind: "hourly", next_run_at: 1.hour.from_now
    )
    never_scheduled = @server.subscriptions.create!(
      feed: feed2, discord_channel_id: 4444, created_by_discord_user_id: 3333,
      mode: "digest", schedule_kind: "hourly"
    )

    assert_equal [ due ], Subscription.due_digests.to_a
    assert_not_includes Subscription.due_digests, not_due
    assert_not_includes Subscription.due_digests, never_scheduled
  end

  test "digest mode requires schedule_kind" do
    sub = @server.subscriptions.new(
      feed: @feed, discord_channel_id: 2222, created_by_discord_user_id: 3333,
      mode: "digest"
    )
    assert_not sub.valid?
    assert_includes sub.errors[:schedule_kind], "is required for digest mode"
  end
end
