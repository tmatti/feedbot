module Feedbot
  module Feeds
    class Parser
      def self.upsert(feed, body)
        new(feed, body).upsert
      end

      def initialize(feed, body)
        @feed = feed
        @body = body
      end

      # Returns array of newly created Entry records
      def upsert
        parsed = Feedjira.parse(@body)

        @feed.update!(title: parsed.title.presence || @feed.title) if parsed.title.present?

        new_entries = []
        parsed.entries.each do |item|
          guid = item.entry_id.presence || item.url
          next if guid.blank?

          entry = @feed.entries.find_or_initialize_by(guid: guid)
          next unless entry.new_record?

          entry.assign_attributes(
            url: item.url,
            title: item.title,
            summary: extract_summary(item),
            image_url: extract_image(item),
            published_at: item.published || item.updated || Time.current
          )
          entry.save!
          new_entries << entry
        end

        new_entries
      end

      private

      def extract_summary(item)
        (item.summary || item.content).presence
      end

      def extract_image(item)
        item.respond_to?(:image) ? item.image : nil
      end
    end
  end
end
