class PostDigestJob < ApplicationJob
  queue_as :default

  def perform(sub_id, entry_ids)
    sub = Subscription.find_by(id: sub_id)
    return unless sub

    entries = Entry.where(id: entry_ids).order(:published_at)
    return if entries.empty?

    client = Feedbot::Discord::RestClient.new
    chunks = entries.each_slice(10).to_a

    chunks.each do |chunk|
      embeds = chunk.map { |e| Feedbot::Discord::EmbedBuilder.build(e, sub.feed) }
      begin
        client.post_message(sub.discord_channel_id, embeds: embeds)
        chunk.each do |entry|
          Delivery.find_or_create_by!(subscription: sub, entry: entry) do |d|
            d.posted_at = Time.current
          end
        end
      rescue Feedbot::Discord::RestClient::DiscordError => e
        chunk.each do |entry|
          Delivery.find_or_create_by!(subscription: sub, entry: entry) do |d|
            d.error = e.message
          end
        end
        break if [10003, 50001].include?(e.code)
      rescue Feedbot::Discord::RestClient::RateLimitError => e
        sleep(e.retry_after)
        retry
      end
    end
  end
end
