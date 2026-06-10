module Feedbot
  module Discord
    class EmbedBuilder
      def self.build(entry, feed)
        embed = {
          title: entry.title&.truncate(256),
          url: entry.url,
          description: entry.summary&.gsub(/<[^>]+>/, "")&.truncate(300),
          author: { name: feed.title&.truncate(256) },
          timestamp: entry.published_at&.iso8601,
          color: 0x5865F2
        }
        embed[:thumbnail] = { url: entry.image_url } if entry.image_url.present?
        embed.compact
      end
    end
  end
end
