require "openssl/hmac"
require "uri"
require "./decoder/converter"
require "./decoder/codecs"

module Gori
  # RFC 6238 time-based one-time codes, for `$GEN.TOTP` (#1591): a session slot's refresh step,
  # or any request an operator authors, carries a code that is valid at the moment it is sent.
  #
  # Pure: a secret in, a code out. Where the secret lives and when a code is minted belong to
  # `Env`, so nothing here knows about a surface, a Store or the env table.
  module Totp
    ALGORITHMS = {
      "SHA1"   => OpenSSL::Algorithm::SHA1,
      "SHA256" => OpenSSL::Algorithm::SHA256,
      "SHA512" => OpenSSL::Algorithm::SHA512,
    }

    # RFC 4226 §5.3 asks for at least 6. 10 is the most a 31-bit truncation can fill.
    DIGITS = 6..10

    record Config, key : Bytes, digits : Int32 = 6, period : Int32 = 30,
      algorithm : OpenSSL::Algorithm = OpenSSL::Algorithm::SHA1

    # The code `config` gives at `at`: RFC 4226 dynamic truncation of the HMAC of the
    # big-endian `at / period` counter, zero-padded to `digits`.
    def self.code(config : Config, at : Time) : String
      counter = Bytes.new(8)
      IO::ByteFormat::BigEndian.encode((at.to_unix // config.period).to_u64, counter)
      mac = OpenSSL::HMAC.digest(config.algorithm, config.key, counter)
      bin = IO::ByteFormat::BigEndian.decode(UInt32, mac[mac[-1] & 0x0f, 4]) & 0x7fff_ffff
      (bin.to_i64 % 10_i64 ** config.digits).to_s.rjust(config.digits, '0')
    end

    # The secret `value` holds, or why it cannot be one, phrased to follow the name of
    # whatever held it ("env var X is …"). Two forms: a bare base32 secret, which means
    # SHA1, 6 digits and 30 s, or the `otpauth://totp/…?secret=…` URI an enrollment QR code
    # carries, whose `digits`, `period` and `algorithm` override those.
    #
    # A reason NEVER quotes the value: it is a second factor, and these sentences reach a
    # toast, a CLI error and an MCP result. `base32_decode`'s own message quotes the
    # offending character, which is why it is replaced rather than passed on.
    def self.parse(value : String) : Config | String
      value = value.strip
      return "is empty" if value.empty?
      return parse_uri(value) if value.downcase.starts_with?("otpauth:")
      (bytes = key(value)) ? Config.new(bytes) : "is not a base32 secret or an otpauth://totp/ URI"
    end

    private def self.parse_uri(value : String) : Config | String
      uri = URI.parse(value)
      kind = uri.host.try(&.downcase)
      return "is an otpauth://hotp/ URI, and only TOTP is supported" if kind == "hotp"
      return "is an otpauth: URI but not an otpauth://totp/ one" unless kind == "totp"
      params = uri.query_params
      secret = params["secret"]?.presence || return "is an otpauth://totp/ URI with no secret parameter"
      bytes = key(secret) || return "is an otpauth://totp/ URI whose secret is not base32"
      case options = uri_options(params)
      in String then "is an otpauth://totp/ URI whose #{options}"
      in Tuple  then Config.new(bytes, *options)
      end
    rescue
      # Not only `URI::Error`: a port past Int32 raises `OverflowError`, and this runs at the
      # send seam, which must never raise.
      "is not a parseable otpauth: URI"
    end

    # `{digits, period, algorithm}` from the URI's parameters, absent ones at the bare-secret
    # defaults, or which one is wrong.
    private def self.uri_options(params : URI::Params) : {Int32, Int32, OpenSSL::Algorithm} | String
      digits = (d = params["digits"]?) ? d.to_i? || 0 : 6
      return "digits is not #{DIGITS.begin} to #{DIGITS.end}" unless DIGITS.includes?(digits)
      period = (pe = params["period"]?) ? pe.to_i? || 0 : 30
      return "period is not a positive number of seconds" unless period > 0
      algorithm = ALGORITHMS[params["algorithm"]?.try(&.upcase) || "SHA1"]? ||
                  return "algorithm is not #{ALGORITHMS.keys.join(", ")}"
      {digits, period, algorithm}
    end

    private def self.key(text : String) : Bytes?
      bytes = Decoder::Codecs.base32_decode(text)
      bytes.empty? ? nil : bytes
    rescue Decoder::DecoderError
      nil
    end
  end
end
