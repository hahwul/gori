require "./proxy/codec/http1"

module Gori
  # Compression Dictionary Transport (RFC 9842), and gori's one answer to it (#1898).
  #
  # A client that holds a dictionary names it in `Available-Dictionary` (its SHA-256, plus a
  # `Dictionary-ID` when the dictionary had one), and the origin may then answer
  # `Content-Encoding: dcb` (Brotli) or `dcz` (Zstandard): a body that only that dictionary
  # decodes. The dictionary is the body of an earlier response, possibly from before the capture
  # or cached before gori was in the path, so gori does not decode these codings. It can stop
  # the client asking for them (`Settings.strip_available_dictionary?`), and it names the cause
  # on a body it could not decode.
  #
  # ONE HOME for the field names, the codings and the sentences, so both transports and the
  # decode note say the same thing, the rule `AltSvc` follows.
  module DictionaryTransport
    # Lower-cased, for the byte compare in `Codec::Http1.strip_header_lines`, paired with the
    # spelling the evidence quotes.
    FIELDS = {"available-dictionary" => "Available-Dictionary", "dictionary-id" => "Dictionary-ID"}

    CODINGS = {"dcb", "dcz"}

    # The values are client-chosen and unbounded, and they are quoted into the flow advisory.
    EVIDENCE_MAX = 80

    # How many removed fields the sentence quotes. One request may repeat either field.
    NOTE_MAX_QUOTED = 4

    # Is `enc` (a lower-cased content coding) one only the client's dictionary decodes?
    def self.coding?(enc : String) : Bool
      CODINGS.includes?(enc)
    end

    # Is `name` one of the two request fields the strip removes? Case-insensitive: RFC 9113
    # §8.2.1 asks h2 for lowercase names, but a peer's bytes are a peer's bytes.
    def self.field?(name : String) : Bool
      FIELDS.has_key?(name.downcase)
    end

    # `name: value` as the advisory quotes it, the value bounded.
    def self.evidence(name : String, value : String) : String
      v = value.scrub.strip
      "#{FIELDS[name.downcase]? || name}: #{v[0, EVIDENCE_MAX]}"
    end

    # `head` with every `Available-Dictionary` and `Dictionary-ID` line removed, and the
    # evidence for each one removed. The SAME slice comes back when nothing matched, so a
    # caller can tell by identity that it still holds the client's bytes (P7).
    #
    # Whole fields only. `Accept-Encoding` keeps its `dcb`/`dcz` tokens: an origin cannot
    # produce either coding without the dictionary hash the removed field carried, so the
    # tokens left behind do nothing, and editing part of a field-value would put gori's own
    # spelling of a client-chosen field on the wire, which `AltSvc.strip_h3` refuses for the
    # same reason. The field goes whole or stays whole.
    def self.strip_request(head : Bytes) : {Bytes, Array(String)}
      removed = [] of String
      kept = head
      FIELDS.each do |lower, _|
        kept = Proxy::Codec::Http1.strip_header_lines(kept, lower) do |value|
          removed << evidence(lower, String.new(value))
          true
        end
      end
      {kept, removed}
    end

    # The removals still true of the head that went out: `removed` minus every field a
    # Match&Replace rule put back (`present`, the lower-cased names the sent head carries).
    def self.unrestored(removed : Array(String), present : Array(String)) : Array(String)
      return removed if present.empty?
      removed.reject { |ev| present.includes?(name_of(ev)) }
    end

    # The same, for an HTTP/1.1 head as sent.
    def self.unrestored(removed : Array(String), sent : Bytes) : Array(String)
      _, back = strip_request(sent)
      unrestored(removed, back.map { |ev| name_of(ev) })
    end

    private def self.name_of(evidence : String) : String
      evidence[0, evidence.index(':') || evidence.size].downcase
    end

    # The sentence both transports put on the flow: how many fields, quoted, why, and the switch.
    def self.removal_note(removed : Array(String)) : String
      quoted = removed.first(NOTE_MAX_QUOTED).join(", ")
      quoted += ", and #{removed.size - NOTE_MAX_QUOTED} more" if removed.size > NOTE_MAX_QUOTED
      "removed #{removed.size} dictionary field#{removed.size == 1 ? "" : "s"} (#{quoted}) from " \
      "this request — a response compressed against a dictionary gori does not hold (RFC 9842 " \
      "dcb/dcz) cannot be decoded (settings network.strip_available_dictionary)."
    end

    # The decode note for a `dcb`/`dcz` body. Static, not branched on the switch: the note is a
    # view of a stored flow that may predate any setting. `compressed: ` is the prefix
    # `ContentDecode.decode_failed?` reads, and `unsupported` is what the History pane colours
    # as an incomplete read.
    def self.decode_note(enc : String) : String
      "compressed: #{enc} — unsupported without the client's dictionary (RFC 9842); " \
      "settings network.strip_available_dictionary"
    end
  end
end
