require "uri"
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
      # `Location`, when the response carried one. A redirect's WHOLE content is this header:
      # its body is usually empty, so two 3xx replies compare as identical no matter where
      # they send the client. See `Judge.redirect_verdict`.
      getter location : String?
      # What the HEAD says about an entity that was NOT transmitted. Read only when the body
      # is absent by protocol (`entity_suppressed?`) — there the emptiness carries no
      # information and these two are the only description of the resource on the wire.
      getter content_length : Int64?
      getter etag : String?
      # The REQUEST was a HEAD. A property of the request, not the response, so it has to be
      # carried in: a HEAD reply never has a body no matter what it is describing.
      getter? head_request : Bool

      def initialize(@status : Int32?, @size : Int64?, @simhash : UInt64, @error : String? = nil,
                     @location : String? = nil, @content_length : Int64? = nil,
                     @etag : String? = nil, @head_request : Bool = false)
      end

      # Could this response have carried a body at all? A HEAD reply and a `304 Not Modified`
      # describe an entity they deliberately do NOT send, so "both bodies were empty" says
      # nothing whatsoever about whether the two identities were served the same resource.
      #
      # A `204`/`205` is deliberately NOT here: there the emptiness IS the entity — the action
      # succeeded and returned nothing — so two matching 204s remain the same evidence they
      # always were (see `Judge.content_matches?`).
      def entity_suppressed? : Bool
        @head_request || @status == 304
      end

      # From a live send. Decodes the body for the fingerprint; `Repeater::Result` carries the
      # raw head/body and the send error.
      def self.of(result : Repeater::Result, head_request : Bool = false) : ResponseSummary
        return new(nil, nil, 0_u64, error: result.error) unless result.ok?
        status = status_of(result.head)
        location = header_of(result, "location")
        length = header_of(result, "content-length").try(&.strip.to_i64?)
        etag = header_of(result, "etag").try(&.strip.presence)
        decoded, _ = Proxy::Codec::ContentDecode.decode(result.head, result.body)
        body = decoded || result.body
        size = body && !body.empty? ? body.size.to_i64 : 0_i64
        hash = body && !body.empty? ? Discover::Fingerprint.simhash(body) : 0_u64
        new(status, size, hash, location: location, content_length: length, etag: etag,
          head_request: head_request)
      end

      # One header from a finished send. The parsed `RawResponse` when the sender produced one,
      # else a scan of the raw head — a `Repeater::Result` built without a parse (an h2 bridge,
      # a hand-built one in a spec) still has its bytes, and reading only the parsed half made
      # every field below silently nil for it.
      private def self.header_of(result : Repeater::Result, name : String) : String?
        if resp = result.response
          if v = resp.headers.get?(name)
            return v
          end
        end
        head_header(result.head, name)
      end

      # First `name:` field value in a raw response head, case-insensitively. Byte-level and
      # line-oriented for the same reason `ResponseSummary.status_of` is: a head off a socket
      # need not be valid UTF-8.
      private def self.head_header(head : Bytes, name : String) : String?
        return nil if head.empty?
        target = name.downcase
        start = 0
        first = true
        i = 0
        while i <= head.size
          if i == head.size || head.unsafe_fetch(i) == 0x0a_u8
            stop = i
            stop -= 1 if stop > start && head.unsafe_fetch(stop - 1) == 0x0d_u8
            line = String.new(head[start, stop - start])
            return nil if !first && line.empty? # end of the head
            if !first && (ci = line.index(':')) && line[0, ci].strip.downcase == target
              return line[(ci + 1)..].strip
            end
            first = false
            start = i + 1
          end
          i += 1
        end
        nil
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
        #
        # But only in ONE DIRECTION, which the rule missed. `Different` aggregates the row to
        # `enforced`, and that word is a claim about the identity under test getting LESS than
        # the baseline. When it got a 2xx and the baseline did not, the opposite happened: a
        # `403 → 200` (the baseline denied, this identity served) and a `304 → 200` (the
        # baseline's conditional GET revalidated, this identity handed the whole entity) are
        # both an identity receiving content the baseline never saw. Painting those green is
        # the worst way this tool can fail, so a same-or-better outcome for the other side is
        # `Review` — the verdict whose meaning is "the operator judges" — and never `Different`.
        if bs != os
          return Verdict::Review if os == 2 && bs != 2
          return Verdict::Different
        end

        # BOTH REDIRECTS: where they point is the answer, and it is the only part of a redirect
        # that carries one. The body is empty, so `content_matches?` matched every 3xx pair
        # against every other — and the textbook enforcement pattern, an authenticated
        # `302 → /dashboard` against an anonymous `302 → /login`, came back `Same`. That is not
        # a noisy verdict, it is the finding inverted: the row an operator most needs to read as
        # "access control engaged" was the one painted red as a bypass.
        if bs == 3
          verdict = redirect_verdict(baseline, other)
          return verdict if verdict
        end

        # Same status class. Now the body decides. No body on either side (a 204 with an empty
        # entity, a redirect neither side gave a Location) → same class + same emptiness is a
        # match.
        same_content = content_matches?(baseline, other)
        return Verdict::Same if same_content

        # Same status, divergent body: could be a per-user page that legitimately differs, or a
        # tailored "access denied" rendered at 200. The operator judges.
        Verdict::Review
      end

      # Two 3xx responses, judged on their `Location`. Nil when they cannot be — one of them
      # did not send the header, so there is nothing to compare and the body logic below is
      # still the best available answer.
      #
      # Three outcomes, not two, and the middle one is the point. A byte-exact match is `Same`
      # and a different DESTINATION is `Different` — `/dashboard` against `/login` is access
      # control engaging. But two redirects to the same resource that differ in their query
      # (`/dashboard?sid=A` against `/dashboard?sid=B`, a per-session token in the URL) sent
      # BOTH identities into the protected area, and calling that `Different` aggregates the
      # row to `enforced` and makes the finding vanish. A missed bypass is the one direction
      # this tool must not fail in, so a same-resource difference is `Review` — the verdict
      # whose whole meaning is "the operator judges".
      private def self.redirect_verdict(baseline : ResponseSummary,
                                        other : ResponseSummary) : Verdict?
        b, o = baseline.location, other.location
        return nil if b.nil? || o.nil?
        return Verdict::Same if b == o
        same_destination?(b, o) ? Verdict::Review : Verdict::Different
      end

      # Do two `Location` values name the same resource, differing only in query or fragment?
      # Scheme/host/port/path, compared as written — no normalisation beyond what `URI` does,
      # since `/login` and `/login/` are two paths to an origin and guessing otherwise is
      # deciding for the operator. An unparseable value is not the same as anything.
      private def self.same_destination?(a : String, b : String) : Bool
        ua, ub = URI.parse(a), URI.parse(b)
        ua.scheme == ub.scheme && ua.host == ub.host && ua.port == ub.port && ua.path == ub.path
      rescue URI::Error
        false
      end

      # Whether two decoded bodies count as the same content — both empty, or within SimHash
      # distance AND size band. Both guards matter: SimHash skips numeric/hex tokens, so two
      # differently-sized pages can hash close; the size band catches that.
      private def self.content_matches?(a : ResponseSummary, b : ResponseSummary) : Bool
        # A body that could not be sent is not a body that matched. See `suppressed_matches?`.
        return suppressed_matches?(a, b) if a.entity_suppressed? || b.entity_suppressed?
        sa, sb = a.size, b.size
        return true if (sa.nil? || sa == 0) && (sb.nil? || sb == 0)
        return false if sa.nil? || sb.nil? || sa == 0 || sb == 0
        return false unless Discover::Fingerprint.hamming(a.simhash, b.simhash) <= SAME_DISTANCE
        larger = {sa, sb}.max
        smaller = {sa, sb}.min
        (larger - smaller).to_f <= larger.to_f * SIZE_TOLERANCE
      end

      # Two responses whose body the PROTOCOL forbade — a HEAD request, a `304 Not Modified`
      # (see `ResponseSummary#entity_suppressed?`). "Both bodies were empty" is true of every
      # such pair and means nothing: the entity exists on both sides and neither was sent.
      # Reading it as a content match made `Same` — and so `BYPASS` — the automatic answer for
      # a whole response family, and HEAD is in `Passive::SAFE_METHODS`, so passive replay
      # painted ordinary endpoints red without anyone pressing a key.
      #
      # What the two heads DECLARE about the entity is the evidence that is actually there. An
      # `ETag` names the representation, so equal ETags are the same resource and different
      # ETags are not; failing that, an equal `Content-Length` is the same claim about its
      # size. When neither head describes the entity there is nothing to compare, and no match
      # lands the row on `Review` — an operator's look — instead of a manufactured finding.
      #
      # A genuine empty ENTITY (a 204, a `Content-Length: 0` 200) never reaches here: there the
      # emptiness is the resource, and matching emptiness stays the match it always was.
      private def self.suppressed_matches?(a : ResponseSummary, b : ResponseSummary) : Bool
        ea, eb = a.etag, b.etag
        return ea == eb if ea && eb
        ca, cb = a.content_length, b.content_length
        return ca == cb if ca && cb
        false
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
