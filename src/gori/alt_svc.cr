require "./proxy/codec/http1"

module Gori
  # `Alt-Svc` (RFC 7838), and gori's one answer to the HTTP/3 advertisement inside it.
  #
  # gori does not intercept HTTP/3. QUIC is UDP and every listener gori has is a TCP socket,
  # so an origin answering `Alt-Svc: h3=":443"` is inviting the client onto a transport
  # nothing here can read — and what the operator sees afterwards is a target that quietly
  # stopped talking. "I found nothing" and "I could not see it" read identically in an empty
  # History, which is why this header gets a switch (`Settings.strip_alt_svc?`) and not only
  # the warning `Probe::Analyzer` already emits.
  #
  # ONE HOME for the parse. The probe rule REPORTS the advertisement and the proxy REMOVES
  # it; if those two ever disagreed about what "advertises h3" means, a flow would be flagged
  # for a header gori had already taken off the wire, or — worse — stripped without anything
  # saying so. The predicate lived in `Probe::Passive::Tech` first and moved here the moment
  # the proxy became its second caller, which is the rule `request_token_safe?` had to learn
  # three times (#390, #394, #397).
  module AltSvc
    # The field-name, lower-cased for the byte compare in `Codec::Http1.strip_header_lines`.
    FIELD_NAME = "alt-svc"

    # Evidence is quoted back into an issue and a flow advisory, so it is bounded here rather
    # than at each caller: a field-value is remote-chosen and has no length gori controls.
    EVIDENCE_MAX = 80

    # The first `h3` / `h3-*` alternative in an `Alt-Svc` field-value, as evidence text, or
    # nil when the value advertises no HTTP/3 at all.
    #
    # RFC 7838 §3: the value is a comma-separated list of `protocol-id=authority` entries with
    # optional `;`-parameters. Three things this deliberately does NOT match:
    #
    #   * `clear` — RFC 7838 §3, "forget every alternative you have cached for me". That is
    #     the OPPOSITE of an invitation, and the one spelling of this header gori most wants
    #     delivered to the client.
    #   * `h2=…` — an alternative reached over TCP, so still a CONNECT through gori.
    #   * `fooh3=…` / `h32=…` — the protocol-id is the WHOLE token before `=`, never a
    #     substring, or a strip would eat a field it does not understand.
    #   * a comma INSIDE a quoted-string — see `each_alternative`. `alt-authority` is a
    #     quoted-string by grammar (§3) and a parameter's value may be one too, so an
    #     origin writing `fake=":443"; p="a, h3=x"` advertises no HTTP/3 whatever: a plain
    #     `split(',')` cut that field in two and read `h3=x"` out of the second half, which
    #     removed a header gori does not understand while claiming it had removed an h3
    #     advertisement (P7 — the strip must eat only fields it can name).
    def self.h3_evidence(value : String) : String?
      val = value.scrub
      each_alternative(val) do |trimmed|
        eq = trimmed.index('=')
        next unless eq
        proto = trimmed[0, eq].strip.downcase
        if proto == "h3" || proto.starts_with?("h3-")
          return trimmed[0, {trimmed.size, EVIDENCE_MAX}.min]
        end
      end
      nil
    end

    # Each non-empty `alt-value` of an `Alt-Svc` field, OWS-trimmed, splitting on the commas
    # that are actually list separators.
    #
    # RFC 9110 §5.6.4 (quoted-string): a `"` opens a run in which `,` is DATA and `\` escapes
    # the next octet. Both the `alt-authority` and a parameter value can be one, so a comma
    # inside quotes belongs to the entry, not between two of them.
    #
    # An UNBALANCED quote runs to the end of the value and yields one entry. That errs towards
    # not stripping — the direction P7 asks for here, and the same answer `clear` and `h2=`
    # already get: a field gori cannot parse is a field it does not remove.
    private def self.each_alternative(val : String, &) : Nil
      bytes = val.to_slice
      start = 0
      in_quotes = false
      escaped = false
      i = 0
      while i < bytes.size
        b = bytes.unsafe_fetch(i)
        if escaped
          escaped = false
        elsif in_quotes && b == 0x5c_u8 # '\' — quoted-pair, only inside a quoted-string
          escaped = true
        elsif b == 0x22_u8 # '"'
          in_quotes = !in_quotes
        elsif b == 0x2c_u8 && !in_quotes # ',' — a list separator, at last
          entry = val.byte_slice(start, i - start).strip
          yield entry unless entry.empty?
          start = i + 1
        end
        i += 1
      end
      last = val.byte_slice(start, bytes.size - start).strip
      yield last unless last.empty?
    end

    # :ditto: as a predicate, for a caller that only has to decide.
    def self.advertises_h3?(value : String) : Bool
      !h3_evidence(value).nil?
    end

    # How many removed values a sentence quotes before it stops. The evidence is remote-chosen
    # and there is no bound on how many `Alt-Svc` fields one response may carry: a head packed
    # with them produced a 220 KB advisory, written to `flows.advisory` on every such response,
    # which `capture_max_mib` does not cover and retention counts rows rather than bytes for.
    # The count is always exact; only the quoting is capped.
    NOTE_MAX_QUOTED = 4

    # The sentence both transports put on the flow: what was removed, quoted, and why. One
    # spelling, because an operator comparing an h1 flow with an h2 one is reading the same
    # fact and two wordings would read as two different events.
    def self.removal_note(removed : Array(String)) : String
      "removed #{removed.size} Alt-Svc HTTP/3 advertisement#{removed.size == 1 ? "" : "s"} " \
      "(#{quote_evidence(removed)}) from this response — gori does not intercept HTTP/3, so a " \
      "client acting on it would have left the proxy for a transport gori cannot see " \
      "(settings network.strip_alt_svc)."
    end

    # The MIRROR of `removal_note`, for the switch's other position: what was KEPT, quoted, and
    # what keeping it means. Same one-spelling rule and the same reason — an operator comparing
    # an h1 flow with an h2 one is reading one fact, and two wordings read as two events.
    #
    # This exists because the honest reporting used to live only on the side where nothing is
    # lost. With the strip ON gori says what it took off the wire; with it OFF the advertisement
    # reached the client and gori said NOTHING — in the one configuration where traffic can
    # actually leave the proxy. The operator was then holding a History that stops, and "the
    # target had nothing more to say" and "a chunk of this session went out over QUIC" read
    # identically in it (#835, and `memory: absence-of-finding-reads-as-clean`).
    #
    # A NOTICE and not an edit: with the switch off the origin's head reaches the client
    # byte-identical (P7). Nothing here is on the response path except this sentence.
    #
    # KEPT SHORT, shorter than its mirror. `NOTE_MAX_QUOTED` above records why the quoting is
    # capped — this string is written to `flows.advisory` on every response that carries one,
    # a column `capture_max_mib` does not cover and retention counts rows rather than bytes for.
    # That reasoning applied to the opt-in strip; this half fires in the DEFAULT configuration,
    # where CDN-fronted browsing means most captured flows get one. Every word here is load-
    # bearing: what was kept, the evidence, what a client will do about it, and the switch.
    def self.kept_note(kept : Array(String)) : String
      "kept #{kept.size} Alt-Svc HTTP/3 advertisement#{kept.size == 1 ? "" : "s"} " \
      "(#{quote_evidence(kept)}) in this response — gori does not intercept HTTP/3, so a client " \
      "acting on it leaves the proxy and what it does there is missing from History " \
      "(settings network.strip_alt_svc is off)."
    end

    # The evidence list as one quoted clause, capped at `NOTE_MAX_QUOTED` with an exact count of
    # the remainder. Shared by both sentences so the cap cannot drift to one of them.
    private def self.quote_evidence(evidence : Array(String)) : String
      quoted = evidence.first(NOTE_MAX_QUOTED).join(", ")
      quoted += ", and #{evidence.size - NOTE_MAX_QUOTED} more" if evidence.size > NOTE_MAX_QUOTED
      quoted
    end

    # Every h3 alternative advertised by `values` (one entry per `Alt-Svc` FIELD that carries
    # one), or an empty array. Per FIELD like `strip_h3`, and for the same reason the notice is
    # one sentence per flow rather than one per field — an operator is being told a transport
    # may be leaving, once, not handed a list of header lines.
    #
    # FOR A CALLER THAT ALREADY HOLDS WHOLE VALUES — h2, whose HPACK fields carry them, and any
    # projection-based reader that has accepted what that view drops. It is NOT the read-only
    # twin of `strip_h3` and must not be used as one on an h1 head: `parse_headers` keeps only
    # the first line of an obs-folded field, while `strip_header_lines` deliberately hands its
    # block the JOINED value, so the two views disagree on exactly the head the strip removes.
    # An h1 caller asks `strip_h3` and discards the bytes (`ClientConn#note_alt_svc_kept`).
    def self.h3_evidence_all(values : Array(String)) : Array(String)
      found = [] of String
      values.each do |value|
        if ev = h3_evidence(value)
          found << ev
        end
      end
      found
    end

    # `head` with every `Alt-Svc` line that advertises h3 removed, and the evidence for each
    # one removed. The SAME slice comes back when nothing matched, so a caller can tell by
    # identity whether it still holds the origin's bytes (P7).
    #
    # Per FIELD and not per alternative: a value is rewritten as a whole or not at all. Value
    # surgery — dropping `h3=":443"` out of `h2=":443", h3=":443"` and re-joining the rest —
    # would put gori's own spelling of a remote-chosen field on the wire, and the h2 half of
    # that pair costs no visibility anyway (it is another TCP port, still tunnelled). The
    # field goes whole or stays whole.
    def self.strip_h3(head : Bytes) : {Bytes, Array(String)}
      removed = [] of String
      out = Proxy::Codec::Http1.strip_header_lines(head, FIELD_NAME) do |value|
        if ev = h3_evidence(String.new(value))
          removed << ev
          true
        else
          false
        end
      end
      {out, removed}
    end
  end
end
