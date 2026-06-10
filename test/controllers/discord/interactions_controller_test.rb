require "test_helper"

module Discord
  class InteractionsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @signing_key = Ed25519::SigningKey.generate
      @original_public_key = ENV["DISCORD_PUBLIC_KEY"]
      ENV["DISCORD_PUBLIC_KEY"] = @signing_key.verify_key.to_bytes.unpack1("H*")
    end

    teardown do
      ENV["DISCORD_PUBLIC_KEY"] = @original_public_key
    end

    def post_interaction(payload, sign_with: @signing_key)
      body = payload.to_json
      timestamp = Time.now.to_i.to_s
      signature = sign_with.sign(timestamp + body).unpack1("H*")

      post "/discord/interactions",
        params: body,
        headers: {
          "Content-Type" => "application/json",
          "X-Signature-Timestamp" => timestamp,
          "X-Signature-Ed25519" => signature
        }
    end

    test "responds to a signed PING with PONG" do
      post_interaction({ type: 1 })

      assert_response :success
      assert_equal({ "type" => 1 }, JSON.parse(response.body))
    end

    test "rejects an unsigned-key request with 401" do
      post_interaction({ type: 1 }, sign_with: Ed25519::SigningKey.generate)

      assert_response :unauthorized
    end

    test "dispatches a signed command end to end" do
      server = Server.create!(discord_id: 1111, name: "Test Server")
      feed   = Feed.create!(url: "https://example.com/feed.xml", title: "Example Feed")
      server.subscriptions.create!(
        feed: feed, discord_channel_id: 2222, created_by_discord_user_id: 3333, mode: "realtime"
      )

      post_interaction({
        type: 2,
        guild_id: server.discord_id.to_s,
        data: { name: "feed", options: [ { name: "list", options: [] } ] }
      })

      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 4, body["type"]
      assert_equal "Example Feed", body.dig("data", "embeds", 0, "fields", 0, "name")
    end
  end
end
