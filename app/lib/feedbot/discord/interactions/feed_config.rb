module Feedbot
  module Discord
    module Interactions
      class FeedConfig
        def initialize(interaction)
          @interaction = interaction
        end

        def call
          guild_id = @interaction["guild_id"].to_i
          tz_value = @interaction.dig("data", "options", 0, "options", 0, "options", 0, "value")

          unless tz_value.present?
            return text_response("No timezone provided.", ephemeral: true)
          end

          unless ActiveSupport::TimeZone[tz_value] || TZInfo::Timezone.get(tz_value) rescue false
            return text_response("Unknown timezone: `#{tz_value}`. Use an IANA timezone name (e.g. `America/New_York`).", ephemeral: true)
          end

          server = Server.find_or_create_by!(discord_id: guild_id) do |s|
            s.name = guild_id.to_s
          end
          server.update!(timezone: tz_value)

          server.subscriptions.active.digest.each(&:compute_next_run_at!)

          text_response("Server timezone set to **#{tz_value}**. Digest schedules updated.")
        end

        private

        def text_response(content, ephemeral: false)
          data = { content: content }
          data[:flags] = 64 if ephemeral
          { type: 4, data: data }
        end
      end
    end
  end
end
