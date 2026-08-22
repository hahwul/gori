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
    def self.h3_evidence(value : String) : String?
      val = value.scrub
      val.split(',').each do |entry|
        trimmed = entry.strip
        next if trimmed.empty?
        parts = trimmed.split('=', 2)
        next if parts.size < 2
        proto = parts[0].strip.downcase
        if proto == "h3" || proto.starts_with?("h3-")
          return trimmed[0, {trimmed.size, EVIDENCE_MAX}.min]
        end
      end
      nil
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
      quoted = removed.first(NOTE_MAX_QUOTED).join(", ")
      quoted += ", and #{removed.size - NOTE_MAX_QUOTED} more" if removed.size > NOTE_MAX_QUOTED
      "removed #{removed.size} Alt-Svc HTTP/3 advertisement#{removed.size == 1 ? "" : "s"} " \
      "(#{quoted}) from this response — gori does not intercept HTTP/3, so a client acting on " \
      "it would have left the proxy for a transport gori cannot see " \
      "(settings network.strip_alt_svc)."
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
