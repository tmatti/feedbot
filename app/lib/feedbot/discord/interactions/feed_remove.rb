module Feedbot
  module Discord
    module Interactions
      class FeedRemove
        def initialize(interaction)
          @interaction = interaction
        end

        def call
          guild_id = @interaction["guild_id"].to_i
          options  = parse_options(@interaction.dig("data", "options", 0, "options") || [])
          sub_id   = options["id"].to_i

          server = Server.find_by(discord_id: guild_id)
          sub    = server&.subscriptions&.find_by(id: sub_id)

          unless sub
            return text_response("Subscription not found.", ephemeral: true)
          end

          feed_title = sub.feed.title.presence || sub.feed.url
          sub.destroy!
          text_response("Removed subscription to **#{feed_title}**.")
        end

        def autocomplete
          guild_id = @interaction["guild_id"].to_i
          server   = Server.find_by(discord_id: guild_id)

          choices = if server
            server.subscriptions.active.includes(:feed).limit(25).map do |sub|
              {
                name: (sub.feed.title.presence || sub.feed.url).truncate(100),
                value: sub.id.to_s
              }
            end
          else
            []
          end

          { type: 8, data: { choices: choices } }
        end

        private

        def parse_options(options_array)
          options_array.each_with_object({}) { |opt, h| h[opt["name"]] = opt["value"] }
        end

        def text_response(content, ephemeral: false)
          data = { content: content }
          data[:flags] = 64 if ephemeral
          { type: 4, data: data }
        end
      end
    end
  end
end
