require "json"
require "./settings"
require "./store"

module Gori
  # Global + per-project environment variables for `$KEY`-style substitution in
  # outbound requests (Repeater, Fuzzer, Miner, Intercept, CLI, MCP). The editor
  # keeps the raw `$KEY` text; `expand` runs at send time only. Highlighting
  # reuses the same prefix/KEY rules via `token_regions`.
  module Env
    DEFAULT_PREFIX   = "$"
    PROJECT_VARS_KEY = "env.vars"
    KEY_HEAD         = /[A-Za-z_]/
    KEY_TAIL         = /[A-Za-z0-9_]/

    # What a scan does with `$$`, the ONE escape and the only way to put a literal `$NAME`
    # on the wire.
    #
    # `$NAME`'s grammar (`$` + `[A-Za-z_]` + `[A-Za-z0-9_]*`) is byte-identical to a GraphQL
    # variable reference, a MongoDB operator and a JSON Schema keyword, and the scan runs over
    # the whole message including the body. Those are not chance collisions — a parameterised
    # GraphQL document is MADE of `$id` / `$input` / `$userId`, and `id` / `ref` / `token` are
    # the most obvious names an operator gives an env var or an extract rule. So the operator
    # needs a way to say "this `$` is mine". `Rules#substitute` has had one since #501; this
    # brings the same spelling to every other seam.
    #
    # TWO modes because a request is expanded TWICE — the ENV-VAR layer at plan-build
    # (`expand_wire`, #356) and the BINDING layer at send (`expand_bindings`, #501) — and a
    # String is the only channel between them. Consuming the escape in the first pass would
    # hand the second pass a bare `$id` it would then resolve, so `$$id` would still not
    # survive. The layer that runs LAST is therefore the one that consumes:
    #
    #   * `Preserve` — the env-var pass. `$$` is copied through as `$$` and the token behind
    #     it is NOT read, so an env var named `id` cannot resolve into `$$id`.
    #   * `Consume` — `expand_bindings`, the send seam every wire path passes through
    #     (`Repeater::Sender`, `Fuzz::Sender`, `Discover::Engine`). `$$` → one literal `$`,
    #     the token behind it left alone.
    #
    # A surface whose env pass IS the last pass (the TUI intercept editor forwards straight to
    # the origin) asks for `Consume` explicitly. An EVIDENCE path expands nothing at all and
    # so unescapes nothing: a `$$` in captured bytes is two bytes the origin sent, not an
    # escape the operator typed.
    #
    # One place deliberately keeps `$$` as two bytes: a DIAL TUPLE (a `--target`, a URL, an
    # SNI). Those run `Env.expand` once and are never re-scanned by a send seam, so nothing
    # consumes the escape — and there is nothing to escape FROM, because `$` is not a legal
    # byte in a hostname. `unresolved` still walks the escape correctly, so a
    # `$$` there cannot be mis-reported as an unresolved name; it simply fails to resolve as a
    # host, visibly, which is the honest outcome.
    #
    # Escapes pair left to right, one `$` out per `$$` in: `$$id` → `$id`, `$$$$` → `$$`,
    # `$$$id` → `$` followed by an INTERPRETED `$id`.
    enum Escape
      Preserve
      Consume
    end

    @@highlight_rev : UInt32 = 0

    def self.highlight_rev : UInt32
      @@highlight_rev
    end

    def self.bump_highlight_rev : Nil
      @@highlight_rev += 1
    end

    # Merged vars: global first, then project (project wins on KEY collision).
    def self.effective_vars : Hash(String, String)
      h = {} of String => String
      Settings.env_vars.each { |(k, v)| h[k] = v }
      Settings.project_env_vars.each { |(k, v)| h[k] = v }
      h
    end

    # ── the send-time layer (session bindings, #501) ──────────────────────────
    #
    # `$NAME` has exactly ONE syntax and TWO resolution times, and the split is the
    # point of the feature. An env var is BUILD-time: every plan builder expands it
    # once before a run starts (#356), and a name that resolves to nothing is refused
    # there (#519/#525). A BINDING is SEND-time: its value is observed from a response
    # and may change between request 1 and request 20 of the same run, which is exactly
    # the run that otherwise produces a page of 401s.
    #
    # So the two layers are never merged for expansion. `expand`'s default stays
    # `effective_vars` — build-time and static — and the send pass below resolves the
    # binding half ALONE. That is what keeps #356's "one Env.expand, at plan-build"
    # invariant literally true: nothing re-expands an env var, and a var whose value
    # happens to contain a `$` cannot acquire a second meaning on the way to the socket.
    #
    # An abstract Layer rather than a direct reference to `Gori::Bindings` so `env.cr`
    # stays free of Store/Repeater/InterceptFilter — everything the binding table needs
    # and nothing this module should know about.
    abstract class Layer
      # Names an extract rule declares, whether or not one is bound yet.
      abstract def declared : Array(String)
      # Values available for RESOLUTION — what `$NAME` may expand to at send time.
      abstract def values : Hash(String, String)

      # Every value the layer is HOLDING, resolvable or not. Defaults to `values`; a layer
      # whose two answers differ must override it. `Bindings` does: it keeps a disabled
      # rule's token so re-enabling costs no round trip, while refusing to resolve it. See
      # `Env.masking_vars` — a secret that stopped resolving has not stopped being a secret.
      def held_values : Hash(String, String)
        values
      end

      # Bumped on every rule edit and every rebind, so a consumer can cache a merged
      # snapshot instead of rebuilding one per message (see `Rules`).
      abstract def rev : UInt64
    end

    # The open project's binding table, or nil when none is open. Set by `Session.open`
    # and cleared on close — the same per-project-global lifetime `Settings.project_env_vars`
    # already has, and for the same reason: `$SESSION` must mean one thing in the Rewriter,
    # a Repeater tab, a Fuzzer template and `--target` alike. A constructor argument would
    # have guaranteed only that the four send seams remember it, while leaving every OTHER
    # surface free to forget — the opposite of the property the feature needs.
    @@layer : Layer? = nil

    def self.layer : Layer?
      @@layer
    end

    def self.layer=(l : Layer?) : Layer?
      @@layer = l
      bump_highlight_rev
      l
    end

    # Names declared by an extract rule. A declared name is NOT "unresolved" at plan-build
    # time — it resolves later, at send — so `unresolved` skips it by default and the send
    # seams pass `deferred: nil` to get it back.
    def self.declared_bindings : Array(String)
      @@layer.try(&.declared) || [] of String
    end

    # Bound values only. Never merged into `effective_vars`; see the note above.
    def self.binding_values : Hash(String, String)
      @@layer.try(&.values) || {} of String => String
    end

    def self.binding_rev : UInt64
      @@layer.try(&.rev) || 0_u64
    end

    # What a DISPLAY path should treat as known: build-time vars plus whatever is bound
    # right now. Widening the default of `mask_secrets` / `token_regions` to this is what
    # makes every surface that already masks (or paints a `$KEY`) cover bindings too,
    # with no per-surface change. Deliberately NOT the default of `expand`.
    def self.display_vars : Hash(String, String)
      h = effective_vars
      binding_values.each { |(k, v)| h[k] = v }
      h
    end

    # What a MASKING surface must treat as secret: build-time vars plus every value the
    # binding layer is holding, INCLUDING one whose rule is currently disabled.
    #
    # Deliberately wider than `display_vars`, and the two must not be merged. `display_vars`
    # answers "what will resolve", which is what `token_regions` paints and what completion
    # offers — a disabled name is not resolvable and must not paint as bound. Masking asks a
    # different question: those bytes were observed from a real response and are sitting in
    # memory, so a redaction that stopped the moment the operator toggled a rule off would
    # print the token into an export, a note or the detail view.
    def self.masking_vars : Hash(String, String)
      h = effective_vars
      (@@layer.try(&.held_values) || {} of String => String).each { |(k, v)| h[k] = v }
      h
    end

    # Substitute BOUND binding values in final wire bytes, at send time. Returns the same
    # slice when there is nothing to do — the common case, and byte-fidelity (P7) besides.
    #
    # Scans the whole message, head and body: injecting a token into a body is a designed
    # case (a `Replace` rule with `part: Body`, an operator's Repeater template). That is
    # safe in a way a head-only rule was not, because this matches a SPECIFIC declared name
    # rather than the `$`+`[A-Za-z_]` shape — and in any case nothing here refuses: a name
    # that does not resolve simply stays literal.
    # A value carrying CR/LF/NUL is withheld from the HEAD half and substituted freely in the
    # BODY. A binding value is the ORIGIN'S — see `Bindings.boundary_forging?` — and in a head
    # `abc\r\nX-Admin: true` becomes two header lines while `abc\r\n\r\nGET /...` forges a whole
    # second request onto a pooled keep-alive upstream. In a body it forges nothing, and the
    # sentence above is the designed case, so the split is by POSITION rather than by value.
    # A name whose value is withheld stays LITERAL, `Env.expand`'s documented contract for an
    # unknown key — visible in the request rather than silently dropped.
    #
    # `verbatim` names byte ranges of `bytes` that this pass must copy through with no scan
    # at all. The doc above justifies scanning the WHOLE message by naming the cases that
    # want it — a `Replace` rule with `part: Body`, an operator's Repeater template — and a
    # FUZZ PAYLOAD is not one of them: the operator authored `$TOKEN` as the thing under
    # test, and substituting the live session token there both sends a request nobody wrote
    # and puts a real credential in an arbitrary position of it, where it lands in the
    # target's access log. `Fuzz::Generator#emit` already computes each payload's span in
    # order to splice it, so the template resolves and the payload does not.
    def self.expand_bindings(bytes : Bytes, verbatim : Array({Int32, Int32})? = nil) : Bytes
      prefix = Settings.env_prefix
      return bytes if prefix.empty? || !contains_prefix?(bytes, prefix)
      vals = binding_values
      # With nothing to resolve this pass would be a no-op — except that it is also the seam
      # that CONSUMES `$$` (see `Escape`), and a project with no extract rule is exactly where
      # an operator escaping a GraphQL `$id` is likeliest to be.
      return bytes if vals.empty? && !contains_escape?(bytes, prefix)
      safe = boundary_safe(vals)
      boundary = head_body_boundary(bytes)
      head = expand(String.new(bytes[0...boundary]), safe, prefix,
        clip_spans(verbatim, 0, boundary), Escape::Consume).to_slice
      return head if boundary >= bytes.size
      raw_body = bytes[boundary..]
      body = expand(String.new(raw_body), vals, prefix,
        clip_spans(verbatim, boundary, bytes.size), Escape::Consume).to_slice
      unless body.size == raw_body.size
        shifted = shift_content_length(head, body.size - raw_body.size)
        warn_unshiftable_framing if shifted.same?(head)
        head = shifted
      end
      buf = IO::Memory.new(head.size + body.size)
      buf.write(head)
      buf.write(body)
      buf.to_slice
    end

    # `head` with its `Content-Length` moved by `delta`, every other byte untouched. No-op
    # when the head declares none.
    #
    # ## Why this lives here and why it is a DELTA
    #
    # Binding values resolve at SEND time, which is after every plan builder has framed the
    # request — `Repeater::Plan` runs `resync_content_length`, `Fuzz::Generator#emit` runs
    # `ContentLength.sync`, both over bytes that still hold the literal `$NAME`. Nothing
    # re-framed afterwards, so a `$NAME` in a BODY shipped a Content-Length describing the
    # UNEXPANDED body: on a pipelined send-group the origin read the declared prefix and the
    # remainder became the front of the next request line — gori desyncing its own connection
    # and putting the session token on the wire as a method. A value shorter than the token
    # hangs the connection instead. On h2 a `content-length` disagreeing with the DATA frames
    # is malformed outright (RFC 9113 §8.1.2.6).
    #
    # A DELTA and not a resync, because both framing modes have to survive: an operator with
    # auto-Content-Length OFF (`Repeater`) or `update_content_length` off (`Fuzz`) authored a
    # deliberate mismatch as their payload, and a resync would silently destroy it. Shifting
    # by what the substitution actually added keeps that offset exactly, while a request that
    # WAS in sync stays in sync. It is also why this sits inside `expand_bindings` rather than
    # at the five send seams: the seam that forgets is the one that desyncs.
    # Only the DIGITS move. The field name's spelling, the colon and the optional whitespace
    # on either side are copied through byte-exact, because on this codebase's requests they
    # are the payload: `content-length:   2` with lower-case and extra OWS IS a
    # header-parsing-discrepancy probe, and canonicalising it to `Content-Length: 2` silently
    # sends a different test than the operator wrote.
    #
    # And with MORE THAN ONE Content-Length the shift is refused outright. A CL.CL request is
    # a desync probe whose whole content is the RELATIONSHIP between the two numbers; moving
    # one of them turns the operator's `2/99` into `10/99`, and there is no reading of "which
    # one did they mean" that is not a guess. Refusing leaves their bytes alone — the request
    # still goes out exactly as authored.
    private def self.shift_content_length(head : Bytes, delta : Int32) : Bytes
      span = content_length_digits(head)
      return head unless span
      start, stop = span
      current = String.new(head[start, stop - start]).to_i64?
      return head unless current
      shifted = {current + delta, 0_i64}.max.to_s
      buf = IO::Memory.new(head.size + shifted.bytesize)
      buf.write(head[0, start])
      buf << shifted
      buf.write(head[stop, head.size - stop])
      buf.to_slice
    end

    # The byte range of the Content-Length VALUE's digits, or nil when this head must not be
    # touched. Everything outside that range is copied verbatim, which is the whole point:
    # header casing, the space after the colon and a leading zero are live smuggling and
    # WAF-bypass variables on the send path, and this runs unconditionally with no
    # auto-Content-Length opt-out. `Fuzz::ContentLength.sync` is the same discipline.
    #
    # nil — leave the head exactly as authored — for each of:
    #
    #   * a `Transfer-Encoding` anywhere in the head. The framing is the chunk-size lines
    #     inside the BODY, and gori cannot re-chunk without rewriting the operator's framing
    #     payload. `ContentLength.sync` returns unchanged for chunked too. The caller warns,
    #     because a `$NAME` in a chunked body still desyncs and silence would be worse.
    #   * more than one Content-Length. A CL.CL request is a desync probe whose content IS the
    #     relationship between the two numbers; there is no "which one did they mean" that is
    #     not a guess.
    #   * a line starting with SP or HTAB — an obs-fold continuation. ` Content-Length: 2`
    #     folded under `X-Note:` is part of THAT header's value and invisible to a strict
    #     parser, which is exactly what an obfuscated-framing probe is built on.
    #
    # Line splitting is on LF with an optional preceding CR, per line, so a deliberately
    # MIXED-EOL head is handled rather than silently skipped.
    private def self.content_length_digits(head : Bytes) : {Int32, Int32}?
      found = nil.as({Int32, Int32}?)
      pos = 0
      first = true
      while pos < head.size
        lf = head.index(0x0a_u8, pos)
        stop = lf || head.size
        line_end = (stop > pos && head[stop - 1] == 0x0d_u8) ? stop - 1 : stop
        unless first || fold_or_blank?(head, pos, line_end)
          case header_name(head, pos, line_end)
          when "transfer-encoding" then return nil
          when "content-length"
            return nil if found # a second one: refuse, see above
            found = value_digits(head, pos, line_end)
          end
        end
        first = false
        break unless lf
        pos = lf + 1
      end
      found
    end

    # An obs-fold continuation (SP/HTAB first) or an empty line — neither is a header of its
    # own, and treating a fold as one is how a `Content-Length` hidden inside another header's
    # value gets edited.
    private def self.fold_or_blank?(head : Bytes, pos : Int32, line_end : Int32) : Bool
      pos >= line_end || head[pos] == 0x20_u8 || head[pos] == 0x09_u8
    end

    private def self.header_name(head : Bytes, pos : Int32, line_end : Int32) : String?
      colon = index_in(head, 0x3a_u8, pos, line_end)
      colon ? String.new(head[pos, colon - pos]).strip.downcase : nil
    end

    # The value's digit span with the OWS on both sides excluded, or nil when the value is
    # empty. The colon is re-found rather than threaded so `header_name` stays a pure lookup.
    private def self.value_digits(head : Bytes, pos : Int32, line_end : Int32) : {Int32, Int32}?
      colon = index_in(head, 0x3a_u8, pos, line_end)
      return nil unless colon
      vs = colon + 1
      while vs < line_end && (head[vs] == 0x20_u8 || head[vs] == 0x09_u8)
        vs += 1
      end
      ve = line_end
      while ve > vs && (head[ve - 1] == 0x20_u8 || head[ve - 1] == 0x09_u8)
        ve -= 1
      end
      ve > vs ? {vs, ve} : nil
    end

    @@warned_unshiftable = false

    # A binding substitution changed the body's length and the head's framing could not follow
    # — chunked, a CL.CL pair, an obs-folded Content-Length, or no Content-Length at all. The
    # message goes out as authored, which for a chunked body means the chunk-size lines now
    # disagree with the chunk: the same desync the Content-Length shift exists to prevent,
    # surviving in the other framing mode. gori will not re-chunk (that would rewrite the
    # framing the operator authored), so the honest answer is to say so. Once per process:
    # this is a send loop.
    private def self.warn_unshiftable_framing : Nil
      return if @@warned_unshiftable
      @@warned_unshiftable = true
      ::Log.warn do
        "a session binding changed a request body's length, but its head's framing could not " \
        "be adjusted (chunked, more than one Content-Length, an obs-folded one, or none). The " \
        "request goes out exactly as authored, so its declared framing may now disagree with " \
        "the body — bind the value into a header, or size the body yourself"
      end
    end

    private def self.index_in(bytes : Bytes, byte : UInt8, from : Int32, to : Int32) : Int32?
      i = from
      while i < to
        return i if bytes[i] == byte
        i += 1
      end
      nil
    end

    # The String form has no head/body split to take, so the caller says whether what it holds
    # is boundary-sensitive. A `--target` or an SNI lands on the request line or in a header
    # and is (`guard_boundary: true`, the default); a WebSocket frame is ALL payload — there is
    # no head in it for a CR/LF to forge a line into, and the proxy's own WS path agrees
    # (`Rules#head_scoped?` maps `part: Ws` to false). Withholding there would kill exactly the
    # multi-line values this feature allows: a PEM block, a SAML assertion, a formatted JSON
    # sub-document.
    def self.expand_bindings(text : String, guard_boundary : Bool = true) : String
      prefix = Settings.env_prefix
      return text if prefix.empty? || !text.byte_index(prefix)
      vals = binding_values
      return text if vals.empty? && !contains_escape?(text.to_slice, prefix) # see the Bytes form
      expand(text, guard_boundary ? boundary_safe(vals) : vals, prefix, escape: Escape::Consume)
    end

    # `spans` restricted to `[from, to)` and rebased so 0 is `from` — what a half of a
    # head/body split needs when the caller's offsets are into the whole message. Returns
    # nil (not an empty Array) when nothing survives, so the scans below keep their
    # allocation-free fast path on the overwhelmingly common "no verbatim regions" call.
    # Spans arrive sorted and disjoint (`Fuzz::Generator` emits them in splice order) and
    # come out that way, which is what lets the scanners walk them with one cursor.
    private def self.clip_spans(spans : Array({Int32, Int32})?, from : Int32,
                                to : Int32) : Array({Int32, Int32})?
      return nil if spans.nil? || spans.empty?
      out = [] of {Int32, Int32}
      spans.each do |(a, b)|
        s = a > from ? a : from
        e = b < to ? b : to
        out << {s - from, e - from} if e > s
      end
      out.empty? ? nil : out
    end

    # `vals` minus every value that would forge a message boundary where it is injected.
    # Returns the SAME Hash when nothing is withheld, which is the common case.
    private def self.boundary_safe(vals : Hash(String, String)) : Hash(String, String)
      return vals unless vals.any? { |(_, v)| Bindings.boundary_forging?(v) }
      vals.reject { |_, v| Bindings.boundary_forging?(v) }
    end

    # Declared binding names in `bytes` that have no value yet, first-appearance order.
    #
    # A REPORT, never a gate. `$NAME` without a value is a literal string on the wire — the
    # same answer `expand` has always given an unknown key, now given to a DECLARED-but-unbound
    # name too. The send seams used to refuse here (#491/#525's shape) and no longer do: the
    # token grammar collides structurally with GraphQL `$id`, Mongo `$ne` and JSON Schema
    # `$ref`, so a name an operator declared for one request silently killed every OTHER
    # request whose captured body happened to contain it — a probe scan losing 7 of 9 active
    # checks on a flow, reported as scanned. An operator who wants a value on the wire binds
    # it; an operator who wrote `$ne` gets `$ne`, and `$$ne` if they need the escape.
    #
    # The one remaining caller is `Rules#report_refused`, which explains a rewrite rule that
    # did not apply — a rule-scoped SKIP that blocks no traffic, not a send refusal.
    #
    # `verbatim` is `expand_bindings`' argument and has to be the SAME list, so the two agree
    # about which bytes are the operator's payload rather than a reference.
    def self.unbound(bytes : Bytes, verbatim : Array({Int32, Int32})? = nil) : Array(String)
      unbound(String.new(bytes), verbatim)
    end

    def self.unbound(text : String, verbatim : Array({Int32, Int32})? = nil) : Array(String)
      declared = declared_bindings
      return [] of String if declared.empty?
      prefix = Settings.env_prefix
      return [] of String if prefix.empty? || !text.byte_index(prefix)
      vals = binding_values
      # `deferred: nil` — the whole point here is to REPORT a declared name, and only a
      # declared one: an unknown `$FOO` is plan-build's business (#525) and reporting it
      # again from a send seam would be the second behaviour for one syntax the design
      # rules out.
      names = scan_unresolved(text.to_slice, vals, prefix, nil, verbatim)
      names.select { |n| declared.includes?(n) }
    end

    private def self.contains_prefix?(bytes : Bytes, prefix : String) : Bool
      pb = prefix.to_slice
      return false if pb.empty? || pb.size > bytes.size
      i = 0
      last = bytes.size - pb.size
      while i <= last
        return true if pb.each_with_index.all? { |b, j| bytes[i + j] == b }
        i += 1
      end
      false
    end

    # Expand env tokens in wire-form HTTP text (LF or CRLF) and return CRLF bytes.
    # Normalizes newlines with a byte-level scan (`normalize_crlf`) — NOT
    # `gsub(/\r?\n/, "\r\n")` and NOT `split('\n').join("\r\n")` — for two reasons:
    # the gsub-vs-split/join distinction avoids doubling already-CRLF input
    # (captured flow bytes) into `\r\r\n`, which would destroy the head/body
    # separator and break framing on every CLI/MCP repeater+mine send path; and a
    # `Regex` (gsub) *requires* valid UTF-8 and raises `ArgumentError` on a subject
    # string that isn't — which a captured flow's binary body routinely isn't. See
    # `expand` below for why the text reaching this point may carry invalid UTF-8.
    #
    # CRLF normalization is HEAD-ONLY: a raw `0x0A` inside the BODY is just a byte
    # (binary/compressed data, or a bare LF a client legitimately sent) — not a line
    # ending — and must never be rewritten to `0x0D 0x0A`. Only HTTP header lines
    # require CRLF termination on the wire; the editors that feed this (Repeater,
    # Miner) store the whole head+body blob as one LF-joined buffer, so naively
    # normalizing the entire buffer corrupted every bare-LF byte in the body
    # (silently, since Content-Length gets resynced to the corrupted body
    # afterward). `head_body_boundary` locates the blank-line separator first;
    # only the head (through and including that separator) is normalized, and the
    # body is copied through byte-for-byte untouched.
    #
    # `escape` defaults to `Preserve`: this is the plan-build pass and `expand_bindings` runs
    # over the same bytes at the send seam. A surface where THIS is the last pass before the
    # socket (the TUI intercept editor) passes `Escape::Consume`.
    def self.expand_wire(text : String, vars : Hash(String, String) = effective_vars,
                         prefix : String = Settings.env_prefix,
                         escape : Escape = Escape::Preserve) : Bytes
      bytes = expand(text, vars, prefix, escape: escape).to_slice
      boundary = head_body_boundary(bytes)
      head = normalize_crlf(bytes[0...boundary])
      return head if boundary >= bytes.size

      body = bytes[boundary..]
      buf = IO::Memory.new(head.size + body.size)
      buf.write(head)
      buf.write(body)
      buf.to_slice
    end

    # `expand_wire` MINUS the expansion: the head's bare LFs promoted to CRLF, every body
    # byte copied through untouched.
    #
    # `expand_wire` is two passes welded together and EVIDENCE wants exactly one of them.
    # Substituting a project value into a captured `$filter` / `$where` sends a request
    # nobody captured (`Repeater::PlanOptions#evidence?` argues this at length); promoting a
    # bare LF in the head is different — the TUI editors hold a request as an LF-joined line
    # buffer and `TextArea#insert_newline` names `expand_wire` as what promotes a typed
    # line's terminator back, so an evidence path that skipped it would put a bare-LF header
    # terminator — itself a front-end/back-end desync primitive — on the wire.
    #
    # Public and here rather than re-derived per surface: `FuzzerView#evidence_template`
    # already spells this out by hand, and a fourth copy is how two surfaces come to
    # disagree about the bytes they send for one flow.
    def self.normalize_wire(text : String) : Bytes
      bytes = text.to_slice
      boundary = head_body_boundary(bytes)
      head = normalize_crlf(bytes[0...boundary])
      return head if boundary >= bytes.size
      body = bytes[boundary..]
      buf = IO::Memory.new(head.size + body.size)
      buf.write(head)
      buf.write(body)
      buf.to_slice
    end

    # Substitute registered `prefix+KEY` tokens; unknown keys stay literal.
    #
    # Operates on raw bytes, not `String#chars`. `prefix` and KEY names are always
    # ASCII (`KEY_HEAD`/`KEY_TAIL`), so a token can be found/replaced by scanning
    # bytes alone — never decoding to codepoints. That matters because the text
    # here can be a captured flow's body loaded verbatim into the Repeater editor,
    # which may contain byte sequences that are not valid UTF-8 (a raw binary
    # body). `String#chars` (the previous implementation) decodes lossily: any
    # invalid sequence is silently replaced by U+FFFD, corrupting the wire bytes
    # on every send — even when the text has no `$KEY` token at all. Scanning
    # bytes instead means every span that isn't part of a matched token — valid
    # UTF-8 or not — is copied through byte-for-byte, unchanged.
    #
    # `verbatim` byte ranges are copied through with no token scan at all. Not the same
    # thing as "no variable happened to match there": the ranges are bytes whose PROVENANCE
    # differs from the rest of the message (today, a fuzz payload spliced into a template),
    # so a `$NAME` inside one is the operator's test case rather than a reference. nil — the
    # overwhelmingly common call — keeps the loop exactly as it was.
    #
    # `escape` says what `$$` means here — see `Escape`. The default is `Preserve` because
    # this method IS the env-var layer, and the binding layer scans the same bytes afterwards.
    def self.expand(text : String, vars : Hash(String, String) = effective_vars,
                    prefix : String = Settings.env_prefix,
                    verbatim : Array({Int32, Int32})? = nil,
                    escape : Escape = Escape::Preserve) : String
      return text if prefix.empty?
      return text unless text.byte_index(prefix) # fast, lossless no-op when the prefix never occurs

      bytes = text.to_slice
      prefix_bytes = prefix.to_slice
      n = bytes.size
      plen = prefix_bytes.size
      buf = IO::Memory.new(n)
      i = 0
      vi = 0 # cursor into `verbatim`; sorted + disjoint, so one pass suffices
      while i < n
        if verbatim
          while vi < verbatim.size && verbatim[vi][1] <= i
            vi += 1
          end
          if vi < verbatim.size && verbatim[vi][0] <= i
            stop = verbatim[vi][1]
            stop = n if stop > n
            buf.write(bytes[i, stop - i])
            i = stop
            next
          end
        end
        if i + plen <= n && prefix_bytes.each_with_index.all? { |b, j| bytes[i + j] == b }
          if prefix_at?(bytes, prefix_bytes, i + plen)
            # `$$` — one escaped literal `$`. Both prefixes are consumed and the token behind
            # them is never read, which is what makes the escape mean the same thing whether
            # or not the name after it happens to resolve.
            buf << prefix
            buf << prefix if escape.preserve?
            i += 2 * plen
          elsif parsed = read_key_bytes(bytes, i + plen, n)
            key, consumed = parsed
            if val = vars[key]?
              buf << val
              i += plen + consumed
            else
              buf << prefix
              i += plen
            end
          else
            buf << prefix
            i += plen
          end
        else
          buf.write_byte(bytes[i])
          i += 1
        end
      end
      String.new(buf.to_slice)
    end

    private def self.prefix_at?(bytes : Bytes, prefix_bytes : Bytes, at : Int32) : Bool
      return false if prefix_bytes.empty? || at + prefix_bytes.size > bytes.size
      prefix_bytes.each_with_index.all? { |b, j| bytes[at + j] == b }
    end

    # Whether `bytes` holds a `$$` anywhere. Only asked on the send seam's "there are no
    # bindings" fast path: with nothing to resolve the pass would be a no-op, EXCEPT that the
    # send seam is also the one that consumes the escape, and skipping it there would ship
    # `$$id` to the origin.
    private def self.contains_escape?(bytes : Bytes, prefix : String) : Bool
      pb = prefix.to_slice
      return false if pb.empty?
      i = 0
      last = bytes.size - 2 * pb.size
      while i <= last
        return true if prefix_at?(bytes, pb, i) && prefix_at?(bytes, pb, i + pb.size)
        i += 1
      end
      false
    end

    # The KEYs in `text` that `expand` would NOT substitute — every `prefix+KEY`
    # whose KEY is unregistered — in first-appearance order, deduplicated. Empty
    # means every token resolved.
    #
    # This is a QUERY, never a mutation of `expand`'s contract: leaving an unknown
    # token literal is correct on a display path (it is honest about what could not
    # be resolved, and `token_regions` already paints it), and wrong on a path that
    # then puts those bytes on a socket. So the send paths ask this first and refuse,
    # and `expand` keeps its meaning for everyone else (issue #519).
    #
    # Shares `read_key_bytes` and mirrors `expand`'s scan positions exactly —
    # INCLUDING the `i += plen` advance on a miss — rather than re-deriving the token
    # grammar. That is what makes the answer trustworthy: a name reported here is a
    # name `expand` tried to resolve at that same offset and could not, so it is a
    # name that lands on the wire literally.
    #
    # NOT `token_regions`, which computes the same `known` fact: that one is
    # char-based (`text.chars`), and the text this runs over is routinely not valid
    # UTF-8 (a captured flow's body loaded verbatim). `String#chars` decodes lossily
    # to U+FFFD, which can both invent and destroy a token boundary — the exact
    # hazard `expand` was made byte-level to avoid.
    #
    # `deferred` names are skipped: a name an extract rule declares is not unresolved, it
    # is resolved LATER (see `unbound`). Without that, `$SESSION` in a Fuzzer template
    # would be refused at plan-build — leaving one syntax with two contradictory rules,
    # which is the thing #525's shape exists to prevent. Pass `nil` to get every name back.
    def self.unresolved(text : String, vars : Hash(String, String) = effective_vars,
                        prefix : String = Settings.env_prefix,
                        deferred : Array(String)? = declared_bindings) : Array(String)
      return [] of String if prefix.empty?
      return [] of String unless text.byte_index(prefix) # same fast no-op as `expand`
      scan_unresolved(text.to_slice, vars, prefix, deferred)
    end

    # Render token names back into the spelling the operator typed (`["A"]` → `"$A"`),
    # comma-joined. Every surface quotes the same list, so the prefix is applied here
    # rather than in five builders that could each drift on whether to include it.
    def self.token_list(names : Array(String), prefix : String = Settings.env_prefix) : String
      names.join(", ") { |n| "#{prefix}#{n}" }
    end

    private def self.scan_unresolved(bytes : Bytes, vars : Hash(String, String),
                                     prefix : String, deferred : Array(String)?,
                                     verbatim : Array({Int32, Int32})? = nil) : Array(String)
      names = [] of String
      seen = Set(String).new
      prefix_bytes = prefix.to_slice
      n = bytes.size
      plen = prefix_bytes.size
      i = 0
      vi = 0 # see `expand`: the same walk over the same sorted, disjoint list
      while i < n
        if verbatim
          while vi < verbatim.size && verbatim[vi][1] <= i
            vi += 1
          end
          if vi < verbatim.size && verbatim[vi][0] <= i
            stop = verbatim[vi][1]
            i = stop > n ? n : stop
            next
          end
        end
        if i + plen <= n && prefix_bytes.each_with_index.all? { |b, j| bytes[i + j] == b }
          if prefix_at?(bytes, prefix_bytes, i + plen)
            # `$$` — an escape, not a reference. Same advance as `expand`'s escape branch, so
            # the two agree about where the NEXT token starts.
            i += 2 * plen
          elsif parsed = read_key_bytes(bytes, i + plen, n)
            key, consumed = parsed
            if vars.has_key?(key)
              i += plen + consumed
            else
              # A DEFERRED name is dropped from the report but still walks the MISS
              # branch: `expand` does not know about bindings, so it re-scans from just
              # past the prefix here, and this has to walk the same offsets or the two
              # could disagree about what a later token even is.
              if seen.add?(key)
                names << key unless deferred && deferred.includes?(key)
              end
              # `i += plen`, NOT `plen + consumed`: see above.
              i += plen
            end
          else
            i += plen
          end
        else
          i += 1
        end
      end
      names
    end

    # Finds the head/body boundary in wire-form text: the byte offset where the
    # body starts, right after the first blank line. Checks for both a bare
    # `\n\n` (how the Repeater/Miner editors store the blob internally) and,
    # defensively, an already-CRLF `\r\n\r\n` (e.g. captured flow bytes loaded
    # verbatim). Returns `bytes.size` when no blank line is found — an all-head
    # buffer (no body), which `expand_wire` then normalizes in full, matching the
    # pre-existing behavior for header-only text.
    # The end of the head (index of the first byte of the body) in wire-form bytes:
    # the FIRST of `\n\n`, `\n\r\n`, or `\r\n\r\n`, whichever occurs earlier — never a
    # fixed preference for one spelling, which is how a body containing a CRLFCRLF has
    # repeatedly moved this boundary in this codebase. Returns `bytes.size` when the
    # message has no terminator at all (a hand-authored head is still a head).
    #
    # Public because it is the ONLY correct answer to this question and every surface
    # that splits a request must share it: MCP's History recording used to scan for
    # `\r\n\r\n` alone and REFUSED to send a bare-LF-terminated request — the exact
    # payload its `verbatim` flag advertises.
    def self.head_body_boundary(bytes : Bytes) : Int32
      n = bytes.size
      i = 0
      while i < n
        if bytes[i] == 0x0A_u8 && i + 1 < n && bytes[i + 1] == 0x0A_u8
          return i + 2
        end
        # `\n\r\n` (0x0A 0x0D 0x0A): a bare-LF header terminator followed by a CRLF blank
        # line. The two neighboring checks both miss it — LFLF needs `bytes[i+1]==0x0A`
        # and CRLFCRLF starts on `0x0D` — so without this branch the message reads as
        # all-head and the body's bare LFs get promoted to CRLF. Body starts at i+3.
        if bytes[i] == 0x0A_u8 && i + 2 < n &&
           bytes[i + 1] == 0x0D_u8 && bytes[i + 2] == 0x0A_u8
          return i + 3
        end
        if bytes[i] == 0x0D_u8 && i + 3 < n &&
           bytes[i + 1] == 0x0A_u8 && bytes[i + 2] == 0x0D_u8 && bytes[i + 3] == 0x0A_u8
          return i + 4
        end
        i += 1
      end
      n
    end

    # Byte-level equivalent of `gsub(/\r?\n/, "\r\n")`: inserts `\r` before any
    # `\n` not already preceded by one, leaving everything else untouched. Used
    # instead of a `Regex` because `bytes` (the expanded request text) may carry
    # invalid UTF-8, which `Regex` cannot accept as a subject. Public: also reused
    # by `gori run intercept edit --raw-file` (a locally-read file may be an
    # arbitrary binary body, same invalid-UTF-8 hazard).
    def self.normalize_crlf(bytes : Bytes) : Bytes
      buf = IO::Memory.new(bytes.size)
      prev : UInt8 = 0
      bytes.each do |b|
        buf.write_byte(0x0D_u8) if b == 0x0A_u8 && prev != 0x0D_u8
        buf.write_byte(b)
        prev = b
      end
      buf.to_slice
    end

    # Scans the text for occurrences of any registered env var value and replaces
    # it with the corresponding token (e.g. "$KEY"). Longest value wins at each
    # position (avoids "secret_value" vs "secret" sub-string collisions).
    #
    # Single left-to-right pass (NOT sequential `gsub` per value): a `gsub` chain
    # can re-match a token an earlier replacement inserted — e.g. value "OKEN"
    # matching inside a just-inserted "$TOKEN" — silently corrupting the mask. The
    # pass never re-scans replaced spans, so inserted tokens stay intact.
    #
    # Byte-level, same reasoning as `expand`: callers pass raw request/response
    # text (e.g. MCP `send`/`repeater` tools mask a captured flow's raw bytes for
    # display), which may not be valid UTF-8. Scanning `text.chars` would silently
    # replace any invalid byte sequence with U+FFFD even where no secret value
    # matches nearby — corrupting the displayed/logged text on every call, not
    # just the masked spans. Byte-level value matching is also strictly more
    # precise than char matching: it finds a value's literal bytes regardless of
    # whether the surrounding haystack happens to be well-formed UTF-8.
    # `masking_vars`, not `effective_vars`: a bound session token is exactly the value a
    # masking surface must not print, and widening the default here is what makes every
    # existing caller mask it without a per-caller change (the design's "for free"). Wider
    # than `display_vars` on purpose — see `masking_vars`: a value whose rule was disabled
    # stops RESOLVING but is still a secret sitting in memory.
    def self.mask_secrets(text : String, vars : Hash(String, String) = masking_vars,
                          prefix : String = Settings.env_prefix) : String
      return text if prefix.empty? || vars.empty?

      # Filter out empty values and short/common values that might lead to false positives (e.g., single characters)
      candidates = vars.to_a
        .reject { |(k, v)| v.strip.empty? || v.size < 4 }
        .sort_by! { |(k, v)| -v.bytesize }
        .map { |(k, v)| {k, v.to_slice} }

      return text if candidates.empty?

      bytes = text.to_slice
      n = bytes.size
      buf = IO::Memory.new(n)
      i = 0
      while i < n
        hit = candidates.find do |(_, vbytes)|
          i + vbytes.size <= n && vbytes.each_with_index.all? { |b, j| bytes[i + j] == b }
        end
        if hit
          buf << prefix << hit[0]
          i += hit[1].size
        else
          buf.write_byte(bytes[i])
          i += 1
        end
      end
      String.new(buf.to_slice)
    end

    # Char offsets [start, end) of each env-shaped token in `text` (end exclusive).
    # Char-based (not byte) — the consumer (Highlight.env_spans_in) slices with
    # `text[a...b]`, which is char-indexed in Crystal, so multi-byte text stays aligned.
    # `known` is true when KEY is registered in `vars`.
    # `known` is `display_vars`-wide, so a BOUND `$SESSION` paints like a set env var and
    # a declared-but-unbound one paints like an unknown key — visible before send, which is
    # the affordance the TUI gets for free and the CLI/MCP have to state in a refusal.
    def self.token_regions(text : String, prefix : String = Settings.env_prefix,
                           vars : Hash(String, String) = display_vars) : Array({Int32, Int32, Bool})
      return [] of {Int32, Int32, Bool} if prefix.empty?
      regions = [] of {Int32, Int32, Bool}
      chars = text.chars
      n = chars.size
      plen = prefix.size
      prefix_chars = prefix.chars
      i = 0
      while i < n
        if i + plen <= n && prefix_chars.each_with_index.all? { |c, j| chars[i + j] == c }
          if i + 2 * plen <= n && prefix_chars.each_with_index.all? { |c, j| chars[i + plen + j] == c }
            # `$$` — an escape. Painting the `$id` inside `$$id` as a resolvable token would
            # tell the operator the opposite of what the wire will carry.
            i += 2 * plen
          elsif parsed = read_key(chars, i + plen, n)
            key, consumed = parsed
            regions << {i, i + plen + consumed, vars.has_key?(key)}
            i += plen + consumed
          else
            i += plen
          end
        else
          i += 1
        end
      end
      regions
    end

    # Parse "KEY VALUE" or "KEY=value" (value may contain spaces when using the
    # space form). Which syntax was used is decided by whichever separator — `=`
    # or whitespace — appears FIRST in the string, not by whether `=` appears
    # anywhere at all: a space-form value that itself contains `=` (e.g. a
    # base64-padded API key, `APIKEY dGVzdA==`) must still split on the leading
    # whitespace, not on the `=` buried inside the value. Returns nil when KEY is
    # invalid.
    def self.parse_line(text : String) : {String, String}?
      raw = text.strip
      return nil if raw.empty?
      eq = raw.index('=')
      ws = raw.index(/\s/)
      if eq && (ws.nil? || eq < ws)
        key = raw[0...eq].strip
        val = raw[eq + 1..]
        return nil unless valid_key?(key)
        {key, val}
      else
        parts = raw.split(/\s+/, 2)
        return nil if parts.size < 2
        key = parts[0]
        return nil unless valid_key?(parts[0])
        {key, parts[1]}
      end
    end

    def self.parse_vars_json(raw : String?) : Array({String, String})
      return [] of {String, String} if raw.nil? || raw.strip.empty?
      arr = JSON.parse(raw).as_a?
      return [] of {String, String} unless arr
      out = [] of {String, String}
      arr.each do |e|
        next unless o = e.as_h?
        key = o["key"]?.try(&.as_s?)
        val = o["value"]?.try(&.as_s?)
        next if key.nil? || key.empty? || val.nil?
        next unless valid_key?(key)
        out << {key, val}
      end
      out
    end

    def self.serialize_vars(vars : Array({String, String})) : String
      JSON.build do |j|
        j.array do
          vars.each do |(key, val)|
            j.object do
              j.field "key", key
              j.field "value", val
            end
          end
        end
      end
    end

    def self.load_project(store : Store) : Nil
      Settings.project_env_vars = parse_vars_json(store.setting(PROJECT_VARS_KEY))
      bump_highlight_rev
    end

    # Returns whether the persisted write committed (false = store busy/locked). The
    # in-memory Settings.project_env_vars is updated regardless (the TUI relies on the
    # immediate update; an MCP caller that got false reloads from the store on its next
    # active tool, so a rolled-back change doesn't stick).
    def self.save_project(store : Store, vars : Array({String, String})) : Bool
      committed =
        if vars.empty?
          store.delete_setting(PROJECT_VARS_KEY)
        else
          store.set_setting(PROJECT_VARS_KEY, serialize_vars(vars))
        end
      Settings.project_env_vars = vars.dup
      bump_highlight_rev
      committed
    end

    def self.valid_key?(key : String) : Bool
      return false if key.empty?
      return false unless KEY_HEAD.matches?(key[0].to_s)
      key.chars[1..].all? { |c| KEY_TAIL.matches?(c.to_s) }
    end

    private def self.read_key(chars : Array(Char), start : Int32, n : Int32) : {String, Int32}?
      return nil if start >= n || !KEY_HEAD.matches?(chars[start].to_s)
      j = start + 1
      while j < n && KEY_TAIL.matches?(chars[j].to_s)
        j += 1
      end
      {chars[start...j].join, j - start}
    end

    # Byte-level counterpart to `read_key`, used by `expand`. KEY_HEAD/KEY_TAIL
    # are pure-ASCII patterns, so matching a single byte at a time via `UInt8#chr`
    # (never decoding a multi-byte sequence) is exact — and safe on invalid UTF-8,
    # since a byte that's part of an invalid sequence simply won't match `[A-Za-z0-9_]`
    # and gets left alone by the caller.
    private def self.read_key_bytes(bytes : Bytes, start : Int32, n : Int32) : {String, Int32}?
      read_key_bytes?(bytes, start, n)
    end

    # Public form: `Rules#substitute` (#501) resolves `$KEY` inside a rule's replacement in
    # ONE pass that also handles `$1` and `$$`, so it cannot call `expand` — but it must
    # read a key EXACTLY the way `expand` does, or the two would disagree about where a
    # token ends.
    def self.read_key_bytes?(bytes : Bytes, start : Int32, n : Int32) : {String, Int32}?
      return nil if start >= n || !KEY_HEAD.matches?(bytes[start].chr.to_s)
      j = start + 1
      while j < n && KEY_TAIL.matches?(bytes[j].chr.to_s)
        j += 1
      end
      {String.new(bytes[start...j]), j - start}
    end
  end
end
