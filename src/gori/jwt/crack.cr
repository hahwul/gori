require "./forge"
require "../secret_crack"

module Gori::Jwt
  # Parse once, then try literal HMAC candidates. No claims or wire segments are rewritten.
  def self.crack(token : String, secrets, *, stop : Proc(Bool)? = nil) : SecretCrack::Result
    parts = token.strip.split('.')
    alg = token_alg(token) || ""
    if refusal = shape_refusal(token, parts, alg)
      raise ForgeError.new(refusal.reason || "not a signed JWS")
    end
    unless digest = HMAC_DIGEST[alg]?
      raise ForgeError.new("cannot crack alg #{alg.inspect}: only HS256/HS384/HS512 use a shared HMAC secret")
    end
    signature = decode_sig(parts[2])
    raise ForgeError.new("the signature segment is not base64") unless signature
    if refusal = sig_shape_refusal(alg, signature)
      raise ForgeError.new(refusal.reason || "malformed signature")
    end
    input = "#{parts[0]}.#{parts[1]}"
    SecretCrack.search(secrets, b64url(signature), stop) do |secret|
      b64url(OpenSSL::HMAC.digest(digest, secret, input))
    end
  end
end
