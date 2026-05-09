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

    Delivery.create!(
      subscription: sub,
      entry: entry,
      posted_at: Time.current,
      discord_message_id: response["id"]&.to_i
    )
  rescue Feedbot::Discord::RestClient::RateLimitError => e
    retry_at = Time.current + e.retry_after.seconds
    retry_job wait: retry_at
  rescue Feedbot::Discord::RestClient::DiscordError => e
    # 10003 = Unknown Channel, 50001 = Missing Access
    if [10003, 50001].include?(e.code)
      sub&.update!(status: "disabled")
    else
      Delivery.create!(
        subscription_id: sub_id,
        entry_id: entry_id,
        error: e.message
      )
    end
  end
end
