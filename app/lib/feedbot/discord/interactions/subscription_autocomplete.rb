module Feedbot
  module Discord
    module Interactions
      class SubscriptionAutocomplete
        def initialize(interaction)
          @interaction = interaction
        end

        def call
          guild_id = @interaction["guild_id"].to_i
          server   = Server.find_by(discord_id: guild_id)

          choices = if server
            scope = server.subscriptions.active.joins(:feed).includes(:feed)
            if query.present?
              q = "%#{ActiveRecord::Base.sanitize_sql_like(query.downcase)}%"
              scope = scope.where("LOWER(feeds.title) LIKE :q OR LOWER(feeds.url) LIKE :q", q: q)
            end
            scope.limit(25).map do |sub|
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

        def query
          options = @interaction.dig("data", "options", 0, "options") || []
          focused = options.find { |opt| opt["focused"] } || options.first
          focused&.dig("value").to_s
        end
      end
    end
  end
end
