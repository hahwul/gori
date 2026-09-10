require "base64"
require "json"

module Gori
  module Jwt
    # JWE — the ENCRYPTED JWT (RFC 7516 compact serialization). Five segments where a JWS
    # has three:
    #
    #   BASE64URL(protected header) . BASE64URL(encrypted key) . BASE64URL(iv)
    #     . BASE64URL(ciphertext) . BASE64URL(tag)
    #
    # gori RECOGNIZES and reads the protected header; it does not decrypt. That is the
    # deliberate first half of the feature and most of its value: until now a JWE reached
    # every gori surface as an opaque dotted string, so an operator could not even learn
    # that the thing in the Authorization header was an encrypted token, let alone which
    # `alg`/`enc` pair produced it. The claims stay behind the content-encryption key.
    #
    # P7 holds: with no key, the header is shown and the body is marked encrypted. gori
    # never guesses at a plaintext it cannot compute.
    module Jwe
      extend self

      # Five base64url segments. Only the header and the AUTHENTICATION TAG are required to be
      # non-empty: the encrypted key is empty for `alg=dir` (nothing is wrapped) and the
      # CIPHERTEXT is empty for an empty plaintext, while an AEAD tag is always present. The
      # first cut had those two quantifiers the other way round, so a JWE over an empty
      # payload failed the shape and was then reported as "declares no `enc`" — which its
      # header plainly did. Everything else is `parse`'s job. There is no separate scan
      # regex: `Jwt::SCAN_RE` already matches up to five segments, so one scan finds both
      # JOSE shapes and `Jwt.narrow` decides which one a match actually is.
      JWE_RE = /\A[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*\.[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\z/

      # One parsed JWE. `header` is the protected header as decoded; the four remaining
      # segments are kept as the base64url text they arrived as — raw bytes are the truth,
      # and nothing here decodes ciphertext.
      record Parsed,
        header : Hash(String, JSON::Any),
        alg : String,
        enc : String,
        encrypted_key : String,
        iv : String,
        ciphertext : String,
        tag : String do
        # The pretty JSON of the protected header, for a pane or a `--format text` block.
        def header_json : String
          JSON::Any.new(header).to_pretty_json
        end

        def kid : String?
          header["kid"]?.try(&.as_s?)
        end

        # `dir` and the ECDH-ES family carry no wrapped key; everything else does.
        def wrapped_key? : Bool
          !encrypted_key.empty?
        end

        # Decoded byte length of a segment, for the "what am I looking at" line. Exact, not an
        # estimate: JWE compact serialization is base64url WITHOUT padding (and `JWE_RE` has no
        # `=` in its character class, so a padded segment never reaches here), which makes the
        # length a pure function of the character count — 4 chars carry 3 bytes.
        def ciphertext_bytes : Int32
          decoded_size(ciphertext)
        end

        private def decoded_size(seg : String) : Int32
          seg.size // 4 * 3 + case seg.size % 4
          when 2 then 1
          when 3 then 2
          else        0
          end
        end
      end

      # Is this a JWE? Five segments AND a protected header that decodes to a JSON object
      # carrying a string `enc`. `enc` is the discriminator, not the segment count: RFC 7516
      # §4.1.2 makes it REQUIRED in a JWE header, and RFC 7515 never defines it for a JWS,
      # so a five-part string without it is some other dotted blob and must not be claimed.
      def jwe?(s : String) : Bool
        !parse(s).nil?
      end

      # The parsed token, or nil when it is not a JWE. Never raises.
      def parse(s : String) : Parsed?
        t = s.strip
        return nil unless t =~ JWE_RE
        parts = t.split('.')
        return nil unless parts.size == 5
        header = JSON.parse(String.new(Base64.decode(parts[0]))).as_h?
        return nil unless header
        enc = header["enc"]?.try(&.as_s?)
        return nil unless enc
        Parsed.new(header, header["alg"]?.try(&.as_s?) || "", enc,
          parts[1], parts[2], parts[3], parts[4])
      rescue
        nil
      end

      # The short claims line for a pane header / scan row. Deliberately NOT the JWS `brief`
      # shape (`alg … exp …`): a JWE has no readable `exp`, and printing one field name in
      # both places would suggest the payload was read.
      def brief(p : Parsed) : String
        bits = ["alg #{p.alg.presence || "?"}", "enc #{p.enc}"]
        bits << "kid #{p.kid}" if p.kid
        bits << "encrypted"
        bits.join(" · ")
      end

      # The text block every decode surface renders for a JWE: the header, then an explicit
      # statement that the claims are encrypted and why nothing is shown for them.
      def render(p : Parsed) : String
        String.build do |io|
          io << "// JWE (encrypted JWT) — 5 segments: header.encrypted_key.iv.ciphertext.tag\n"
          io << "// protected header\n" << p.header_json
          io << "\n\n// payload: ENCRYPTED — gori does not decrypt JWE, so the claims are not shown."
          io << "\n// key management: " << (p.alg.presence || "(no alg in the header)")
          io << (p.wrapped_key? ? " (wrapped key in segment 2)" : " (no wrapped key — a direct/agreed key)")
          io << "\n// content encryption: " << p.enc
          io << " · ciphertext " << p.ciphertext_bytes << " bytes"
          io << "\n// iv: " << (p.iv.presence || "(absent)")
          io << "\n// tag: " << (p.tag.presence || "(absent)")
        end
      end
    end
  end
end
