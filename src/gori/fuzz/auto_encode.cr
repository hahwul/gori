require "./payload"
require "./template"

module Gori::Fuzz
  # WHICH marked positions this run percent-encodes for, and the encode itself.
  #
  # `--auto` finds the position; it used to leave the encoding to the operator. So
  # `gori run fuzz --auto --preset xss` spliced `<script>alert(1)</script>` into `?q=` as
  # raw bytes: the space inside the payload ENDS the request-target, the rest of the
  # payload becomes the HTTP version token, and the origin answers 400 to a request that
  # never carried the payload it was testing. Every playbook grew the same footnote — "add
  # `--encode url`" — which is a default written down in prose instead of in the code, and
  # a tester arriving from Burp or ffuf does not know to read it.
  #
  # So a payload spliced into a QUERY-STRING or FORM-BODY position is percent-encoded by
  # default. The two other things the run could encode for are deliberately left alone:
  # a path segment, a JSON/raw body, a header and a cookie value all stay byte-verbatim,
  # because a `%3C` there is a different test than the one that was marked (and `/`, `.`
  # and `;` are the payload in a traversal or a cookie-injection probe). `Template
  # #urlencoded_positions` draws that line; this struct only decides whether to act on it.
  #
  # It does NOT act when the operator has already said what the bytes should be:
  #
  #   * `--encode` (`Encode`, whatever the kind) — the one processor that names the SPELLING
  #     the wire should carry, so it wins: wrapping `--encode url` would double-encode the
  #     very `%3C` it just produced, and `--encode base64`'s `YWI=` is the operator asking
  #     for that literal, which `--encode base64 --encode url` is how they say otherwise;
  #   * a per-position `§value¦chain§` — the same statement, aimed at one position;
  #   * `--no-encode` / MCP `no_encode:true` — the escape hatch, for a run whose payload IS
  #     the raw byte (HTTP parameter pollution with a bare `&`, a request-line CRLF probe).
  #     A dedicated flag, not `--verbatim`: that one is the Content-Length knob and means
  #     "do not resync framing", a different axis in the same command.
  #
  # The other processors are NOT that statement, and the gate used to be `processors.empty?` —
  # so one `--prefix` turned the whole default off and re-opened the exact failure above:
  # `--payloads '<img src=x onerror=alert(1)>' --prefix P` put `?x=P<img src=x onerror=alert(1)>`
  # on the wire, where the payload's own space ENDS the request-target, the origin read the
  # parameter as `P<img`, and the row still said `1 sent · 0 errors`. `--prefix` / `--suffix` /
  # `--case` / `--hash` / `--regex-replace` say what the PAYLOAD is, not what the wire spells it
  # as, and a payload still has to survive the position it is spliced into — so they keep the
  # default now, and only an `Encode` in the pipeline stands it down. (`--hash`'s hex output and
  # a `--case` over one are unreserved anyway: encoding them is a no-op, not a second encode.)
  #
  # AND FOR A PAYLOAD THAT IS ITSELF A PERCENT-ESCAPE, which is the case this default does not
  # serve. `%` is a reserved byte like any other, so `%00` goes out as `%2500` and reaches the
  # app as three characters rather than a NUL; `..%c0%af..` (the overlong-UTF-8 `/`) arrives as
  # text no normalizer folds. Where the probe's TARGET is the origin's own decoder, that is not
  # a shifted test but no test. The `%2e%2e%2f` family merely SHIFTS — single-decode becomes
  # double-decode, still a real bypass — but not the one that was marked. Deliberately NOT
  # fixed by sniffing for `%`: a wordlist holding `100%` or `50%off` would then silently skip
  # the encoding it needs. The surfaces say so instead (`gori run fuzz`'s up-front note, the
  # `--no-encode` help, MCP `no_encode`, the CLI reference and the fuzz playbook).
  #
  # The encoder is `Encode.new(:url)` — the SAME processor `--encode url` builds, not a new
  # one and not the Decoder catalog's `url-encode` (which is form-style: it turns a space
  # into `+`). One spelling of "URL-encoded" per surface.
  struct AutoEncode
    # `--encode url`'s processor, reused verbatim: percent-encode the reserved bytes,
    # leaving a space as `%20` rather than `+` (a `+` is legal in a query but not in a path
    # or a JSON string, and `%20` reads the same everywhere).
    ENCODER = Encode.new(:url)

    # Positions this run encodes for, by index into `Template#positions`.
    getter positions : Set(Int32)

    def initialize(@positions : Set(Int32))
    end

    # The no-op: an explicit `--encode`, `--no-encode`, or a template with no query/form
    # position at all. Every non-fuzz caller of `Generator` gets this.
    def self.none : AutoEncode
      new(Set(Int32).new)
    end

    # The decision, taken once per plan. `enabled` is the operator's escape hatch and an
    # `Encode` anywhere in `processors` their spelling of the wire bytes (anywhere, not last:
    # `--encode url --suffix '&x=1'` has already produced the `%3C` this must not wrap); a
    # position carrying its own `¦chain` opts out individually.
    def self.build(template : Template, processors : Array(Processor), enabled : Bool) : AutoEncode
      return none unless enabled && processors.none? { |p| p.is_a?(Encode) }
      set = Set(Int32).new
      template.urlencoded_positions.each do |k|
        next unless (pos = template.positions[k]?) && pos.chain.empty?
        set << k
      end
      new(set)
    end

    def none? : Bool
      @positions.empty?
    end

    # Percent-encode the payload at every encoded position that this request actually
    # SUBSTITUTED. `active` is the `Job#position` discriminator: Sniper injects into ONE
    # position and leaves the rest at their template defaults, and a default is already the
    # capture's own bytes — encoding it would turn `?q=a%20b` into `?q=a%2520b` and make
    # every Sniper request a different base request than the one that was marked. nil (the
    # battering-ram / pitchfork / cluster-bomb modes) means every position was substituted.
    #
    # Returns `payloads` ITSELF when nothing applies, so a run with no encoded position
    # renders byte-for-byte the request it always did, with no extra allocation.
    def apply(payloads : Array(String), active : Int32?) : Array(String)
      return payloads if none?
      return payloads if active && !@positions.includes?(active)
      payloads.map_with_index do |v, k|
        (active.nil? || active == k) && @positions.includes?(k) ? ENCODER.apply(v) : v
      end
    end
  end
end
