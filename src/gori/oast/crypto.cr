require "openssl"
require "base64"
require "random/secure"

module Gori::Oast
  # Low-level symmetric crypto + id helpers for the providers (interactsh is the only
  # crypto user). AES via stdlib OpenSSL::Cipher; RSA lives in rsa.cr.
  module Crypto
    extend self

    # DNS-label-safe charset for correlation ids / nonces (WE mint these; the server just
    # echoes them back on the hostname, so lowercase alnum is all that's required).
    CHARSET = "abcdefghijklmnopqrstuvwxyz0123456789"

    def random_id(len : Int32) : String
      String.build(len) { |sb| len.times { sb << CHARSET[Random::Secure.rand(CHARSET.size)] } }
    end

    # AES-256 decrypt an interactsh message: IV = the first 16 bytes, ciphertext = the rest.
    # `mode` is an OpenSSL cipher name ("aes-256-cfb" | "aes-256-ctr"). The interactsh Go
    # server uses CFB; CTR is kept as an auto-detect fallback (see interactsh.cr).
    def aes256_decrypt(data : Bytes, key : Bytes, mode : String) : Bytes
      raise Gori::Error.new("OAST: AES payload too short (#{data.size} bytes)") if data.size <= 16
      iv = data[0, 16]
      ct = data[16..]
      cipher = OpenSSL::Cipher.new(mode)
      cipher.decrypt
      cipher.key = key
      cipher.iv = iv
      io = IO::Memory.new
      io.write(cipher.update(ct))
      io.write(cipher.final)
      io.to_slice
    end
  end
end
