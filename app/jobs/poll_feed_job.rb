class PollFeedJob < ApplicationJob
  queue_as :default

  def perform(feed_id)
    feed = Feed.find_by(id: feed_id)
    return unless feed && feed.status == "active"

    result = Feedbot::Feeds::Fetcher.fetch(feed)

    if result.not_modified
      feed.note_success!(etag: feed.etag, last_modified: feed.last_modified, canonical_url: feed.canonical_url)
      return
    end

    new_entries = Feedbot::Feeds::Parser.upsert(feed, result.body)
    feed.note_success!(etag: result.etag, last_modified: result.last_modified, canonical_url: result.canonical_url)

    realtime_sub_ids = feed.subscriptions.active.realtime.pluck(:id)
    new_entries.each do |entry|
      realtime_sub_ids.each do |sub_id|
        PostDeliveryJob.perform_later(sub_id, entry.id)
      end
    end
  rescue => e
    # Count exactly one failure per poll cycle and let the backoff schedule
    # drive the next attempt — re-raising would have SolidQueue retry and
    # inflate consecutive_failures.
    Rails.logger.error("[PollFeedJob] feed=#{feed_id} #{e.class}: #{e.message}")
    Feed.find_by(id: feed_id)&.note_failure!(e.message)
  end
end
