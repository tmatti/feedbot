class PostDeliveryJob < ApplicationJob
  queue_as :default

  def perform(sub_id, entry_id)
    sub   = Subscription.find_by(id: sub_id)
    entry = Entry.find_by(id: entry_id)
    return unless sub && entry

    # Idempotency: skip if already delivered
    return if Delivery.exists?(subscription_id: sub_id, entry_id: entry_id, skipped: false)

    client = Feedbot::Discord::RestClient.new
    embed  = Feedbot::Discord::EmbedBuilder.build(entry, sub.feed)

    response = client.post_message(sub.discord_channel_id, embeds: [embed])

    # create_or_find_by! treats a concurrent insert for the same
    # (subscription, entry) as success instead of raising RecordNotUnique.
    Delivery.create_or_find_by!(subscription: sub, entry: entry) do |d|
      d.posted_at = Time.current
      d.discord_message_id = response["id"]&.to_i
    end
  rescue Feedbot::Discord::RestClient::RateLimitError => e
    retry_job wait: e.retry_after.seconds
  rescue Feedbot::Discord::RestClient::DiscordError => e
    # 10003 = Unknown Channel, 50001 = Missing Access
    if [10003, 50001].include?(e.code)
      sub&.update!(status: "disabled")
    else
      Delivery.create_or_find_by!(subscription_id: sub_id, entry_id: entry_id) do |d|
        d.error = e.message
      end
    end
  end
end
