class DispatchDueDigestsJob < ApplicationJob
  queue_as :default

  def perform
    Subscription.due_digests.find_each do |sub|
      undelivered = Entry.where(feed_id: sub.feed_id)
                        .where.not(id: sub.deliveries.select(:entry_id))
                        .order(:published_at)
                        .pluck(:id)

      PostDigestJob.perform_later(sub.id, undelivered) if undelivered.any?

      sub.compute_next_run_at!
    end
  end
end
