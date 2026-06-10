module Feedbot
  module Discord
    class SignatureVerifier
      class InvalidSignature < StandardError; end

      def initialize(public_key_hex)
        @verify_key = Ed25519::VerifyKey.new([ public_key_hex ].pack("H*"))
      end

      def verify!(timestamp, body, signature_hex)
        message = timestamp + body
        sig_bytes = [ signature_hex ].pack("H*")
        @verify_key.verify(sig_bytes, message)
      rescue Ed25519::VerifyError
        raise InvalidSignature
      end
    end
  end
end
