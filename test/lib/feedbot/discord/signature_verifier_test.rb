require "test_helper"

class SignatureVerifierTest < ActiveSupport::TestCase
  setup do
    @signing_key = Ed25519::SigningKey.generate
    @public_key_hex = @signing_key.verify_key.to_bytes.unpack1("H*")
    @verifier = Feedbot::Discord::SignatureVerifier.new(@public_key_hex)
    @timestamp = Time.now.to_i.to_s
    @body = { type: 1 }.to_json
  end

  def sign(timestamp, body)
    @signing_key.sign(timestamp + body).unpack1("H*")
  end

  test "accepts a valid signature" do
    signature = sign(@timestamp, @body)
    assert @verifier.verify!(@timestamp, @body, signature)
  end

  test "rejects a tampered body" do
    signature = sign(@timestamp, @body)
    tampered = { type: 2 }.to_json

    assert_raises(Feedbot::Discord::SignatureVerifier::InvalidSignature) do
      @verifier.verify!(@timestamp, tampered, signature)
    end
  end

  test "rejects a tampered timestamp" do
    signature = sign(@timestamp, @body)

    assert_raises(Feedbot::Discord::SignatureVerifier::InvalidSignature) do
      @verifier.verify!((@timestamp.to_i + 1).to_s, @body, signature)
    end
  end

  test "rejects a signature from a different key" do
    other_key = Ed25519::SigningKey.generate
    signature = other_key.sign(@timestamp + @body).unpack1("H*")

    assert_raises(Feedbot::Discord::SignatureVerifier::InvalidSignature) do
      @verifier.verify!(@timestamp, @body, signature)
    end
  end
end
