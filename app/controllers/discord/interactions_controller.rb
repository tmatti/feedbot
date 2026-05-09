module Discord
  class InteractionsController < ApplicationController
    before_action :verify_signature!

    def create
      response = Feedbot::Discord::Interactions::Dispatcher.new.call(interaction_params)
      render json: response
    end

    private

    def verify_signature!
      verifier = Feedbot::Discord::SignatureVerifier.new(ENV.fetch("DISCORD_PUBLIC_KEY"))
      timestamp = request.headers["X-Signature-Timestamp"]
      signature = request.headers["X-Signature-Ed25519"]
      body      = request.raw_post

      verifier.verify!(timestamp, body, signature)
    rescue Feedbot::Discord::SignatureVerifier::InvalidSignature
      render json: { error: "invalid signature" }, status: :unauthorized
    end

    def interaction_params
      # Parse raw POST body as JSON; do NOT use ActionController params filtering
      # because Discord's payload must be passed as-is to the verifier and handlers
      @interaction_params ||= JSON.parse(request.raw_post)
    end
  end
end
