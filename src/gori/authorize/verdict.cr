require "../repeater/engine"
require "../discover/fingerprint"
require "../proxy/codec/content_decode"

module Gori
  module Authorize
    # A response reduced to the three facts a verdict compares: its status, its decoded body
    # size, and a content fingerprint. The body is DECODED first (gzip/deflate/br/chunked) —
    # a SimHash over compressed bytes is meaningless, since a small content change scrambles
    # the whole compressed stream.
    struct ResponseSummary
      getter status : Int32?
      getter size : Int64?    # decoded body size (nil = no body / send error)
      getter simhash : UInt64 # 0 when there is no body to hash
      getter error : String?  # send failure (TLS/DNS/timeout/refused); nil on a real reply

      def initialize(@status : Int32?, @size : Int64?, @simhash : UInt64, @error : String? = nil)
      end

      # From a live send. Decodes the body for the fingerprint; `Repeater::Result` carries the
      # raw head/body and the send error.
      def self.of(result : Repeater::Result) : ResponseSummary
        return new(nil, nil, 0_u64, error: result.error) unless result.ok?
        status = status_of(result.head)
        decoded, _ = Proxy::Codec::ContentDecode.decode(result.head, result.body)
        body = decoded || result.body
        if body && !body.empty?
          new(status, body.size.to_i64, Discover::Fingerprint.simhash(body))
        else
          new(status, 0_i64, 0_u64)
        end
      end

      # The numeric status from a response head, or nil when the head has no parseable status
      # line (an errored/empty exchange). Byte-level and bounded: `HTTP/1.1 200 OK` → 200.
      def self.status_of(head : Bytes) : Int32?
        return nil if head.empty?
        # Find the first space, then read up to three digits after it.
        sp = head.index(0x20_u8)
        return nil unless sp
        i = sp + 1
        n = {head.size, i + 8}.min
        digits = [] of UInt8
        while i < n
          b = head.unsafe_fetch(i)
          break unless b >= 0x30_u8 && b <= 0x39_u8
          digits << b
          i += 1
        end
        return nil if digits.empty?
        String.new(Slice.new(digits.to_unsafe, digits.size)).to_i?
      end
    end

    # The comparison result for one identity's response against the baseline's.
    #
    # The names are neutral because the SECURITY meaning depends on the identity's intended
    # privilege, which only the operator knows: `Same` on a low-privilege identity is a likely
    # access-control BYPASS, while `Same` on a second admin session is expected. The tab states
    # the comparison; the operator reads the intent.
    enum Verdict
      Same      # status and content match the baseline — same resource served
      Different # clearly differs — a different status class, or unrelated content
      Review    # ambiguous — same status but the body diverged, or a redirect
      Error     # this identity's send failed, so nothing could be compared
      Baseline  # this row IS the baseline

      def label : String
        case self
        in Same      then "same"
        in Different then "different"
        in Review    then "review"
        in Error     then "error"
        in Baseline  then "baseline"
        end
      end
    end

    # Decides a `Verdict` from two `ResponseSummary`. Pure and self-contained so it can be
    # spec'd without a socket.
    module Judge
      # Hamming distance under which two decoded bodies count as the same content. SimHash of
      # near-identical pages differs by only a bit or two (see `Discover::Fingerprint`); a
      # genuinely different page is far past this.
      SAME_DISTANCE = 3

      # Fractional size band around the baseline within which a body counts as "same size".
      # Pages carry per-request noise (CSRF tokens, timestamps), so an exact match is too
      # strict; 10% catches real content divergence without flagging that noise.
      SIZE_TOLERANCE = 0.10

      def self.verdict(baseline : ResponseSummary, other : ResponseSummary) : Verdict
        return Verdict::Error if other.error
        # A baseline that itself errored cannot anchor a comparison — treat every other row as
        # needing a manual look rather than asserting same/different against nothing.
        return Verdict::Review if baseline.error

        bs = status_class(baseline.status)
        os = status_class(other.status)
        # A different status CLASS (2xx vs 4xx vs 3xx …) is the clearest signal access control
        # engaged: a 200 baseline turning into a 401/403 for this identity is `Different`.
        return Verdict::Different if bs != os

        # Same status class. Now the body decides. No body on either side (a 204/redirect with
        # an empty entity) → same class + same emptiness is a match.
        same_content = content_matches?(baseline, other)
        return Verdict::Same if same_content

        # Same status, divergent body: could be a per-user page that legitimately differs, or a
        # tailored "access denied" rendered at 200. The operator judges.
        Verdict::Review
      end

      # Whether two decoded bodies count as the same content — both empty, or within SimHash
      # distance AND size band. Both guards matter: SimHash skips numeric/hex tokens, so two
      # differently-sized pages can hash close; the size band catches that.
      private def self.content_matches?(a : ResponseSummary, b : ResponseSummary) : Bool
        sa, sb = a.size, b.size
        return true if (sa.nil? || sa == 0) && (sb.nil? || sb == 0)
        return false if sa.nil? || sb.nil? || sa == 0 || sb == 0
        return false unless Discover::Fingerprint.hamming(a.simhash, b.simhash) <= SAME_DISTANCE
        larger = {sa, sb}.max
        smaller = {sa, sb}.min
        (larger - smaller).to_f <= larger.to_f * SIZE_TOLERANCE
      end

      # The hundreds digit of a status (2 for 2xx, 4 for 4xx …), or 0 when there is none. The
      # class, not the exact code, is what separates "served" from "denied" from "redirected".
      private def self.status_class(status : Int32?) : Int32
        s = status
        return 0 unless s
        s // 100
      end
    end
  end
end
