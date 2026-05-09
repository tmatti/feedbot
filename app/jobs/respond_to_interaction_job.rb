class RespondToInteractionJob < ApplicationJob
  queue_as :default

  def perform(interaction_token:, guild_id:, channel_id:, user_id:, url:, mode:, schedule_kind: nil, schedule_time: nil)
    client = Feedbot::Discord::RestClient.new

    # Find or create the server
    server = Server.find_or_create_by!(discord_id: guild_id) do |s|
      s.name = guild_id.to_s
    end

    # Validate URL format
    unless url =~ /\Ahttps?:\/\//i
      return client.patch_interaction_response(interaction_token, content: "Invalid URL: must start with http:// or https://")
    end

    # Find or create feed (fetch + parse)
    feed = Feed.find_or_initialize_by(url: url)
    if feed.new_record?
      result = Feedbot::Feeds::Fetcher.fetch(feed)
      feed.save!
      Feedbot::Feeds::Parser.upsert(feed, result.body)
      feed.note_success!(etag: result.etag, last_modified: result.last_modified, canonical_url: result.canonical_url)
    end

    # Create subscription
    sub = server.subscriptions.find_or_initialize_by(
      feed: feed,
      discord_channel_id: channel_id
    )

    if sub.persisted?
      return client.patch_interaction_response(interaction_token, content: "Already subscribed to that feed in <##{channel_id}>.")
    end

    sub.assign_attributes(
      created_by_discord_user_id: user_id,
      mode: mode,
      schedule_kind: schedule_kind,
      schedule_time: schedule_time,
      status: "active"
    )

    unless sub.valid?
      return client.patch_interaction_response(interaction_token, content: "Error: #{sub.errors.full_messages.to_sentence}")
    end

    sub.save!
    sub.compute_next_run_at! if mode == "digest"

    # Mark all existing entries as skipped, post the latest one as confirmation
    latest_entry = feed.entries.order(published_at: :desc).first

    feed.entries.each do |entry|
      if entry == latest_entry
        Delivery.create!(subscription: sub, entry: entry, posted_at: Time.current)
      else
        Delivery.create!(subscription: sub, entry: entry, skipped: true)
      end
    end

    if latest_entry
      embed = Feedbot::Discord::EmbedBuilder.build(latest_entry, feed)
      client.patch_interaction_response(
        interaction_token,
        content: "Subscribed to **#{feed.title.presence || url}**! Here's the latest entry:",
        embeds: [embed]
      )
    else
      client.patch_interaction_response(
        interaction_token,
        content: "Subscribed to **#{feed.title.presence || url}**! No entries found yet."
      )
    end

  rescue Feedbot::Feeds::Fetcher::FetchError => e
    begin
      client.patch_interaction_response(interaction_token, content: "Failed to fetch feed: #{e.message}")
    rescue => _; end
  rescue => e
    begin
      client.patch_interaction_response(interaction_token, content: "Something went wrong: #{e.message}")
    rescue => _; end
    raise
  end
end
