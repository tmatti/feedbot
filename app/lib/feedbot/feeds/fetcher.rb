module Feedbot
  module Feeds
    class Fetcher
      Result = Struct.new(:body, :etag, :last_modified, :canonical_url, :not_modified, keyword_init: true)

      def self.fetch(feed)
        new(feed).fetch
      end

      def initialize(feed)
        @feed = feed
      end

      def fetch
        response = connection.get(normalized_url) do |req|
          req.headers["If-None-Match"] = @feed.etag if @feed.etag.present?
          req.headers["If-Modified-Since"] = @feed.last_modified if @feed.last_modified.present?
          req.headers["User-Agent"] = "Feedbot/1.0"
        end

        case response.status
        when 304
          Result.new(not_modified: true)
        when 200..299
          Result.new(
            body: response.body,
            etag: response.headers["ETag"],
            last_modified: response.headers["Last-Modified"],
            canonical_url: response.env.url.to_s,
            not_modified: false
          )
        else
          raise FetchError, "HTTP #{response.status}"
        end
      end

      class FetchError < StandardError; end

      private

      def normalized_url
        @feed.url
      end

      def connection
        Faraday.new do |f|
          f.adapter Faraday.default_adapter
        end
      end
    end
  end
end
