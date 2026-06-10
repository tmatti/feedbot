module Feedbot
  module Discord
    module Interactions
      class FeedList
        PER_PAGE = 10

        def initialize(interaction)
          @interaction = interaction
        end

        def call
          guild_id = @interaction["guild_id"].to_i
          server = Server.find_by(discord_id: guild_id)

          unless server
            return text_response("No feeds configured for this server.")
          end

          total = server.subscriptions.count
          if total.zero?
            return text_response("No active subscriptions. Use `/feed add` to get started.")
          end

          total_pages = (total / PER_PAGE.to_f).ceil
          page = requested_page.clamp(1, total_pages)

          subs = server.subscriptions.includes(:feed)
                       .order(created_at: :desc)
                       .offset((page - 1) * PER_PAGE)
                       .limit(PER_PAGE)

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
            color: 0x5865F2,
            footer: { text: footer_text(page, total_pages, total) }
          }

          { type: 4, data: { embeds: [embed] } }
        end

        private

        def requested_page
          options = @interaction.dig("data", "options", 0, "options") || []
          page = options.find { |opt| opt["name"] == "page" }&.dig("value").to_i
          page.positive? ? page : 1
        end

        def footer_text(page, total_pages, total)
          text = "#{total} subscription#{"s" unless total == 1}"
          text += " | Page #{page} of #{total_pages} — use /feed list page:<n>" if total_pages > 1
          text
        end

        def text_response(content)
          { type: 4, data: { content: content, flags: 64 } }
        end
      end
    end
  end
end
