module Feedbot
  module Discord
    module Interactions
      class FeedEdit
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

          attrs = {}
          attrs[:discord_channel_id]    = options["channel"].to_i if options["channel"]
          attrs[:mode]                  = options["mode"]          if options["mode"]
          attrs[:schedule_kind]         = options["schedule"]      if options["schedule"]
          attrs[:schedule_time]         = options["at"]            if options["at"]

          sub.assign_attributes(attrs)

          unless sub.valid?
            return text_response(sub.errors.full_messages.to_sentence, ephemeral: true)
          end

          sub.save!
          sub.compute_next_run_at! if attrs.key?(:schedule_kind) || attrs.key?(:schedule_time) || attrs.key?(:mode)

          text_response("Updated subscription to **#{sub.feed.title.presence || sub.feed.url}**.")
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
