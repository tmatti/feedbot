module Feedbot
  module Discord
    module Interactions
      class FeedList
        def initialize(interaction)
          @interaction = interaction
        end

        def call
          guild_id = @interaction["guild_id"].to_i
          server = Server.find_by(discord_id: guild_id)

          unless server
            return text_response("No feeds configured for this server.")
          end

          subs = server.subscriptions.includes(:feed).order(created_at: :desc).limit(10)

          if subs.empty?
            return text_response("No active subscriptions. Use `/feed add` to get started.")
          end

          fields = subs.map do |sub|
            schedule_str = sub.mode == "digest" ? " | #{sub.schedule_kind}#{" at #{sub.schedule_time}" if sub.schedule_time.present?}" : ""
            {
              name: sub.feed.title.presence || sub.feed.url,
              value: "<##{sub.discord_channel_id}> | #{sub.mode}#{schedule_str} | #{sub.status}",
              inline: false
            }
          end

          embed = {
            title: "Feed Subscriptions",
            fields: fields,
            color: 0x5865F2
          }

          { type: 4, data: { embeds: [embed] } }
        end

        private

        def text_response(content)
          { type: 4, data: { content: content, flags: 64 } }
        end
      end
    end
  end
end
