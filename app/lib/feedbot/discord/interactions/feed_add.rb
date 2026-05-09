module Feedbot
  module Discord
    module Interactions
      class FeedAdd
        def initialize(interaction)
          @interaction = interaction
        end

        def call
          token      = @interaction["token"]
          guild_id   = @interaction["guild_id"].to_i
          options    = parse_options(@interaction.dig("data", "options", 0, "options") || [])
          channel_id = options["channel"].to_i
          user_id    = @interaction.dig("member", "user", "id").to_i

          RespondToInteractionJob.perform_later(
            interaction_token: token,
            guild_id: guild_id,
            channel_id: channel_id,
            user_id: user_id,
            url: options["url"],
            mode: options["mode"],
            schedule_kind: options["schedule"],
            schedule_time: options["at"]
          )

          { type: 5 }  # DEFERRED_CHANNEL_MESSAGE_WITH_SOURCE
        end

        private

        def parse_options(options_array)
          options_array.each_with_object({}) { |opt, h| h[opt["name"]] = opt["value"] }
        end
      end
    end
  end
end
