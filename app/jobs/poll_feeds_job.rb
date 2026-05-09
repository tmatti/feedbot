class PollFeedsJob < ApplicationJob
  queue_as :default

  def perform
    Feed.due_for_poll.find_each do |feed|
      PollFeedJob.perform_later(feed.id)
    end
  end
end
