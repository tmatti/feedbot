module Feedbot
  module Discord
    module Interactions
      class Dispatcher
        def call(interaction)
          case interaction["type"]
          when 1
            { type: 1 }
          when 2
            dispatch_command(interaction)
          when 4
            dispatch_autocomplete(interaction)
          end
        end

        private

        def dispatch_command(interaction)
          sub = interaction.dig("data", "options", 0, "name")
          case sub
          when "add"    then FeedAdd.new(interaction).call
          when "list"   then FeedList.new(interaction).call
          when "remove" then FeedRemove.new(interaction).call
          when "edit"   then FeedEdit.new(interaction).call
          when "config" then FeedConfig.new(interaction).call
          end
        end

        def dispatch_autocomplete(interaction)
          sub = interaction.dig("data", "options", 0, "name")
          case sub
          when "remove", "edit" then SubscriptionAutocomplete.new(interaction).call
          end
        end
      end
    end
  end
end
