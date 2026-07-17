require "uri"
require "./types"
require "./rsa"

module Gori::Oast
  # A live listening session: the server-side state a `register` minted, plus the local
  # secrets needed to poll + decrypt it. The controller maps this to/from an oast_sessions
  # row; `id` is 0 until persisted, then set to the DB row id (== CallbackEvent.session_id).
  class Session
    property id : Int64
    getter kind : ProviderKind
    getter server_url : String
    getter correlation_id : String # interactsh 20-char corr id; provider token/id otherwise
    getter secret : String         # interactsh 13-char secret; provider secret otherwise
    getter private_key_pem : String? # interactsh RSA private key PEM (nil for others)
    property token : String?         # provider auth token (BOAST secret, webhook/postbin id)
    property? registered : Bool
    # AES mode for interactsh decrypt: CFB (server default) vs CTR fallback. Sticky per
    # session once a poll proves which one yields valid JSON; not persisted (re-derivable).
    property? aes_mode_cfb : Bool

    @rsa : RsaKeyPair?

    def initialize(@id : Int64, @kind : ProviderKind, @server_url : String,
                   @correlation_id : String, @secret : String, *,
                   @private_key_pem : String? = nil, @token : String? = nil,
                   @registered : Bool = false, @aes_mode_cfb : Bool = true,
                   rsa : RsaKeyPair? = nil)
      @rsa = rsa
    end

    # The interactsh RSA keypair, materialized on demand from the persisted PEM (so a
    # resumed session keeps decrypting). nil for non-interactsh sessions.
    def rsa : RsaKeyPair?
      r = @rsa
      return r if r
      pem = @private_key_pem
      return nil unless pem
      @rsa = RsaKeyPair.from_private_pem(pem)
    end

    # The payload host (interactsh server host, or the provider's callback host).
    def host : String
      URI.parse(@server_url).host || @server_url
    end
  end
end
