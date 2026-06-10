module Feedbot
  module Discord
    class RestClient
      class DiscordError < StandardError
        attr_reader :code
        def initialize(message, code: nil)
          super(message)
          @code = code
        end
      end
      class RateLimitError < StandardError
        attr_reader :retry_after
        def initialize(retry_after)
          super("Rate limited")
          @retry_after = retry_after
        end
      end

      def initialize
        @app_id = ENV.fetch("DISCORD_APP_ID")
        @bot_token = ENV.fetch("DISCORD_BOT_TOKEN")
        @conn = Faraday.new("https://discord.com/api/v10") do |f|
          f.request :json
          f.response :json
          f.headers["Authorization"] = "Bot #{@bot_token}"
        end
      end

      def post_message(channel_id, embeds:, content: nil)
        body = { embeds: embeds }
        body[:content] = content if content
        # Paths must be relative: a leading slash would replace the /api/v10
        # prefix of the connection's base URL.
        response = @conn.post("channels/#{channel_id}/messages", body)
        handle_response(response)
      end

      def patch_interaction_response(interaction_token, embeds: nil, content: nil)
        body = {}
        body[:embeds] = embeds if embeds
        body[:content] = content if content
        response = @conn.patch("webhooks/#{@app_id}/#{interaction_token}/messages/@original", body)
        handle_response(response)
      end

      def put_global_commands(commands)
        response = @conn.put("applications/#{@app_id}/commands", commands)
        handle_response(response)
      end

      private

      def handle_response(response)
        if response.status == 429
          retry_after = response.body["retry_after"]&.to_f || 1.0
          raise RateLimitError.new(retry_after)
        elsif response.status >= 400
          code = response.body["code"]
          msg  = response.body["message"] || "HTTP #{response.status}"
          raise DiscordError.new(msg, code: code)
        end
        response.body
      end
    end
  end
end
