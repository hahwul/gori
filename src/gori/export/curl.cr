require "../url"
require "../proxy/h2/head_codec"
require "../proxy/codec/content_decode"
require "./escape"

module Gori
  module Export
    # A captured REQUEST as a ready-to-run `curl` invocation — the serializer behind the
    # TUI's "Copy as → cURL" row (`Tui::CopyMenu`) and `gori run show <id> --format curl`.
    #
    # SURFACE-NEUTRAL on purpose. This used to live entirely inside `src/gori/tui/copy_menu.cr`,
    # which meant the only way for the CLI to emit the same command was to import `Tui::` —
    # or, worse, to write a second curl serializer that would drift from the first the moment
    # either grew a flag. It sits beside `Export::Har` because it is the same kind of thing:
    # bytes gori captured, written out in a shape another tool can run.
    #
    # `Tui::CopyMenu` keeps the menu (the Option records, the wscat row, the response-side
    # formats) and delegates every byte of request parsing and shell quoting here, so the
    # clipboard and the CLI cannot disagree about what this request's curl line is.
    module Curl
      # gori's own annotations on a SYNTHESIZED h2 head (`Proxy::H2::HeadCodec`) — which fields
      # arrived in a trailing HEADERS block, that the origin invented this request in a
      # PUSH_PROMISE, an RFC 8441 `:protocol`. They are gori speaking ABOUT the exchange, not
      # bytes any client put on the wire, so a command that claims to reproduce the request must
      # not send them. Dropped by name rather than by an `x-gori-` prefix sweep: an operator's
      # own header is theirs to send, and these three are the only ones gori writes itself.
      MARKER_HEADERS = [
        Proxy::H2::HeadCodec::TRAILER_MARKER.downcase,
        Proxy::H2::HeadCodec::PUSHED_MARKER.downcase,
        Proxy::H2::HeadCodec::PROTOCOL_MARKER.downcase,
      ]

      # The curl line for one request. `wire` is the request as it'd be sent (CRLF-framed,
      # env-expanded — the bytes repeater uses), `target` the "scheme://host[:port]" base that
      # resolves an origin-form request line ("GET /p HTTP/1.1") into a full URL. nil when there
      # is no resolvable URL, which is the one case there is nothing runnable to hand over.
      def self.text(wire : String, target : String) : String?
        head, body = split_message(wire)
        lines = split_lines(head)
        request_line = lines.first? || ""
        # No request line, no request. An EMPTY head used to reach `resolve_url`, whose
        # target-base fallback answers `https://acme.test` for an empty request-target — so a
        # flow whose capture holds no head at all was handed back as `curl 'https://acme.test'`,
        # a request nobody ever made, offered as if it were the capture. The one case with
        # nothing runnable to hand over now includes the case with nothing captured.
        return nil if request_line.strip.empty?
        # BEFORE `resolve_url`: a line `parse_request_line` cannot frame gives it a target that
        # is some OTHER token, and a URL built from that is a guess. See `request_line_refusal`.
        if refusal = request_line_refusal(request_line)
          return "# no command: #{refusal}"
        end
        header_lines = lines.size > 1 ? lines[1..] : [] of String
        method, req_target, version = parse_request_line(request_line)
        url = resolve_url(req_target, target, header_lines)
        return nil if url.empty?
        command(method, url, header_lines, body, version)
      end

      # A copy-pasteable `curl` invocation reproducing the request. URL first (browser
      # "Copy as cURL" convention), then the protocol flag when the capture was not h1, then -X
      # for the method, each header as -H (dropping Host/Content-Length — curl derives those),
      # then --data-raw for a body. Every argument is single-quoted with embedded quotes
      # escaped, so it survives a paste into any POSIX shell verbatim. Continuation lines keep
      # it readable.
      #
      # EVERY argument means the METHOD too, and that one is not decoration. The method is
      # UNVALIDATED bytes off the wire — `parse_request_head` is `start.split(' ')` with no
      # check at all (`request_token_safe?` exists but is called only by discover / the MCP
      # request builder / the fuzzer's redirect guard, never on the capture path), and the one
      # byte gori does judge is the FIRST, via `looks_like_http_request?`. So every shell
      # metacharacter reaches this line: `` ` ``, `$`, `|`, `&`, `;`, `'`, and CTL/DEL too.
      # (`Import::Builder.reject_inject!` narrows the HAR path to "no CR/LF/NUL" — narrower,
      # still wide open.) Spliced raw, `-X GET;curl|sh` ended the curl command and started a
      # second one IN THE OPERATOR'S SHELL the moment they pasted what gori handed them, which
      # is the one place a hostile capture could aim this command. Quoted like the rest now.
      def self.command(method : String, url : String, header_lines : Array(String),
                       body : String, version : String = "") : String
        # FIRST, and a refusal rather than a note: the URL is the one argument the command IS.
        # There is no curl line without it and no `-X`-style fallback to fall back to, so a NUL
        # in it means there is nothing runnable to hand over — see `nul_url_note`.
        if note = nul_url_note(url)
          return note
        end
        # Every caveat the bytes impose, appended as `#` comments after the last argument. A
        # comment swallows the ` \` that continues its line, so the first of them ends the
        # command — which is why they all sit at the end, and why a second one is still safe
        # (the line it lands on is a comment too).
        notes = [] of String
        # The stored body is WIRE bytes. curl frames `--data-raw` itself, so the chunk framing
        # has to come off with the coding that declared it.
        entity, transfer_encoding = unchunk(header_lines, body, notes)
        parts = ["curl #{shell_quote(Escape.percent_encode_non_ascii(url))}"]
        parts << "--globoff" if globbed?(url)
        if flag = version_flag(version, url)
          parts << flag
        end
        # Emit -X unless it's a plain bodyless GET (curl's default). A GET *with* a body
        # still needs -X GET, else curl silently promotes the request to POST.
        unless method.empty? || (method == "GET" && entity.empty?)
          if note = nul_method_note(method, entity)
            notes << note
          else
            parts << "-X #{shell_quote(method)}"
          end
        end
        te_written = false
        each_header(header_lines) do |name, value|
          down = name.downcase
          next if down == "content-length"
          next if MARKER_HEADERS.includes?(down)
          # curl derives Host FROM THE URL — which is the captured header only when the capture's
          # Host IS the URL's authority. When it is not, that disagreement is the request (a Host
          # header injection test is nothing else), so it has to ride on the command.
          next if down == "host" && host_is_url_authority?(value, url)
          if down == "transfer-encoding" && (te = transfer_encoding)
            next if te_written # the peeled list is emitted once, at the first TE line
            te_written = true
            next if te.empty?
            parts << "-H #{shell_quote("#{name}: #{te}")}"
            next
          end
          if note = nul_header_note(name, value)
            notes << note
            next
          end
          parts << "-H #{shell_quote(header_item(name, value))}"
        end
        parts << data_argument(entity) unless entity.empty?
        # LAST, like `data_argument`'s refusal and for the same reason: a `#` comment swallows
        # the ` \` that continues the line, so a note anywhere earlier would truncate the
        # command it is annotating.
        parts.concat(notes)
        parts.join(" \\\n  ")
      end

      # One `-H` argument's text. `Name: value`, except when the capture's value is EMPTY: a
      # curl header argument with nothing after the colon does not send that header, it REMOVES
      # curl's own default for it, so `X-Empty:` on the wire came out as `-H 'X-Empty: '` and
      # curl sent no such field at all. Measured against a raw listener on curl 8.7.1:
      #
      #   -H 'X-Empty: '   the header is absent from the request
      #   -H 'X-Empty;'    X-Empty: goes out with an empty value
      #
      # `;` is curl's own spelling for "send this one empty", which is what the capture holds —
      # and it is what stops this serializer disagreeing with the Go/Python/fetch ones, whose
      # libraries put an empty value on the wire verbatim.
      private def self.header_item(name : String, value : String) : String
        value.empty? ? "#{name};" : "#{name}: #{value}"
      end

      # The refusal for a URL holding a NUL. The other end of the hole `nul_method_note` and
      # `data_argument` already name, on the one argument that has no fallback: `shell_quote`
      # carries every byte inside '…' except 0x00, and an argv is NUL-terminated. Measured with
      # `curl` replaced by `/bin/echo` so execve's argv is visible, on a stored
      # `GET /pa<NUL>th HTTP/1.1`:
      #
      #   zsh (macOS's default)   ARG https://acme.test/pa    — truncated, SILENTLY
      #   bash                    "cannot execute binary file" / a syntax error on paste
      #
      # So the command would fetch a DIFFERENT resource than the capture, which is the single
      # thing this serializer must never do. Emitting the whole thing as a comment is the only
      # honest shape: a paste does nothing instead of doing the wrong thing.
      private def self.nul_url_note(url : String) : String?
        return nil unless url.to_slice.includes?(0_u8)
        "# no command: the captured URL holds a NUL, which no shell argument can carry — a " \
        "shell truncates the argument there (zsh silently, bash by refusing the line), so curl " \
        "would request a different resource than the capture did. Read the request line with " \
        "--format raw"
      end

      # The refusal for a header whose name or value holds a NUL, or nil when it does not. Same
      # byte, same truncation, one argument over: `-H 'X-Nul: be<NUL>fore'` reaches curl as
      # `X-Nul: be`, so the reproduction sends a header the capture did not. Dropped and named,
      # the way `nul_method_note` drops `-X`.
      #
      # The note itself is written with the NUL ESCAPED — a raw one would truncate the comment
      # that is about it.
      private def self.nul_header_note(name : String, value : String) : String?
        return nil unless name.to_slice.includes?(0_u8) || value.to_slice.includes?(0_u8)
        "# -H omitted for #{nul_escaped(name)}: the captured header holds a NUL, which no shell " \
        "argument can carry — a shell truncates it there and curl would send a header the " \
        "capture did not. Read the head with --format raw"
      end

      # `s` with every NUL byte written as the text `\\0`, for a note ABOUT a NUL. Byte-wise, so
      # a header name that is not valid UTF-8 is not rewritten into U+FFFD on its way into a
      # sentence naming it.
      private def self.nul_escaped(s : String) : String
        bytes = s.to_slice
        io = IO::Memory.new(bytes.size)
        bytes.each do |b|
          b == 0_u8 ? io << "\\0" : io.write_byte(b)
        end
        String.new(io.to_slice)
      end

      # The FINAL `chunked` transfer coding peeled off the body, as {the entity, the
      # Transfer-Encoding value the command should carry instead} — the second nil when nothing
      # declared chunked framing and the TE lines should be emitted as captured, and "" when
      # `chunked` was the only coding and the header goes away entirely.
      #
      # A stored request body is the bytes off the WIRE, chunk framing included, and curl frames
      # `--data-raw` ITSELF. Handed the wire bytes under the capture's own
      # `Transfer-Encoding: chunked`, curl chunked them a second time: the origin decoded 14
      # bytes where the capture sent 5. `--format json` (`note: "de-chunked"`) and the SARIF
      # export both already report the entity, so the one artifact of the three that can actually
      # be RUN was the one lying about what it sends.
      #
      # Only the final `chunked` comes off, and no compression does. A `Transfer-Encoding` of
      # `gzip, chunked` is framing over CONTENT the origin still has to inflate, so the gzip
      # layer stays on the command and on the bytes — the same split `ContentDecode` draws
      # between framing and compression, and the same reason `Content-Encoding` is untouched.
      private def self.unchunk(header_lines : Array(String), body : String,
                               notes : Array(String)) : {String, String?}
        return {body, nil} if body.empty?
        codings = transfer_codings(header_lines)
        return {body, nil} unless codings.last? == "chunked"
        wire = body.to_slice
        entity = String.new(Proxy::Codec::ContentDecode.dechunk(wire))
        complete = Proxy::Codec::ContentDecode.chunked_complete?(wire)
        # A head declaring `chunked` over a body that is NOT chunk-framed — a hand-authored
        # request in the Repeater, an import that stored the entity. `dechunk` is tolerant and
        # recovers NOTHING from one, so peeling would drop the operator's body silently, which is
        # the failure this whole peel exists to avoid. Hand the bytes over as captured and say
        # which of the two the head disagrees with.
        if !complete && entity.empty?
          notes << "# body sent as captured: the head declares Transfer-Encoding: chunked but " \
                   "the stored #{wire.size} bytes are not chunk-framed, so there is no framing " \
                   "to take off — curl will frame them itself"
          return {body, nil}
        end
        cut = complete ? "" : " That stream never reached its terminating 0-chunk, so the " \
                              "capture itself is cut."
        notes << "# body de-chunked: --data-raw carries the #{entity.bytesize}-byte entity, not " \
                 "the #{wire.size} chunk-framed bytes of the capture — curl frames --data-raw " \
                 "itself, and sending the wire bytes under a chunked coding frames them twice." \
                 "#{cut} --format raw has the wire bytes"
        {entity, codings[0, codings.size - 1].join(", ")}
      end

      # Every Transfer-Encoding coding on the request, in wire order, lowercased. Across ALL
      # TE lines: a repeated field is one comma-separated list (RFC 9110 §5.3), so the final
      # coding is the last token of the last line, not of whichever line was looked at.
      private def self.transfer_codings(header_lines : Array(String)) : Array(String)
        out = [] of String
        each_header(header_lines) do |name, value|
          next unless name.downcase == "transfer-encoding"
          value.split(',').each do |tok|
            t = tok.strip.downcase
            out << t unless t.empty?
          end
        end
        out
      end

      # Is the captured `Host` the very authority the URL already carries? Only then is dropping
      # it (for curl to derive from the URL) a reproduction rather than a rewrite. Compared with
      # the scheme's DEFAULT PORT normalised away on both sides and case-insensitively, because
      # `acme.test`, `ACME.test` and `acme.test:443` on an https URL are one authority.
      #
      # Public because the code serializers (`Export::PythonRequests` &c., via
      # `Export::RequestParts`) draw the same Host/URL line curl does — a Host that matches the
      # URL's authority is redundant, a Host that does NOT is the request.
      def self.host_is_url_authority?(host_value : String, url : String) : Bool
        sep = url.index("://")
        return false unless sep
        scheme = url[0, sep].downcase
        rest = url[(sep + 3)..]
        slash = rest.index('/')
        authority = slash ? rest[0, slash] : rest
        # userinfo is curl's to send; it is never part of a Host header (RFC 9110 §7.2).
        if at = authority.rindex('@')
          authority = authority[(at + 1)..]
        end
        normalize_authority(authority, scheme) == normalize_authority(host_value.strip, scheme)
      end

      # An authority lowercased with the scheme's default port removed. An IPv6 literal keeps its
      # brackets: the trailing `:port` is only a port when no `]` follows the last colon.
      private def self.normalize_authority(authority : String, scheme : String) : String
        a = authority.downcase
        default = case scheme
                  when "https", "wss" then "443"
                  when "http", "ws"   then "80"
                  else                     ""
                  end
        return a if default.empty?
        colon = a.rindex(':')
        return a unless colon && a.index(']', colon).nil?
        a[(colon + 1)..] == default ? a[0, colon] : a
      end

      # The refusal for a method holding a NUL, or nil when there is none. Same hole
      # `data_argument` names for the body, on the other end of the same command: `shell_quote`
      # carries every byte inside '…' except 0x00, and an argv is NUL-terminated, so bash
      # TRUNCATES the method there and curl sends a different one than the capture — silently,
      # with `-X 'GET'` on screen looking correct. Reachable on the proxy path only (import
      # refuses NUL); nothing validates it, see `command`.
      #
      # No `-X` is emitted, so curl falls back to its own default, and the note says which.
      private def self.nul_method_note(method : String, body : String) : String?
        return nil unless method.to_slice.includes?(0_u8)
        "# -X omitted: the captured method holds a NUL, which no shell argument can carry — " \
        "bash would truncate it and curl would send #{body.empty? ? "GET" : "POST"} instead. " \
        "Read the request line with --format raw"
      end

      # Does this URL contain a byte curl reads as a URL GLOB rather than as itself? By default
      # curl expands `[a-b]` / `[1-3]` ranges and `{x,y}` lists in the URL argument, which for a
      # captured URL is never what the operator meant. Measured against a raw listener, curl
      # 8.7.1, one command each:
      #
      #   ?f=[1-3]              THREE requests (f=1, f=2, f=3), none of them the capture
      #   ?g={a,b}              TWO requests (g=a, g=b)
      #   ?fields[item]=id      curl: (3) bad range in URL position 32 — nothing sent
      #   ?h=x{y  ?i=]          curl: (3) unmatched brace / unmatched close brace — nothing sent
      #
      # The third is not exotic: `fields[item]=…` is a JSON:API sparse fieldset, and gori's own
      # demo project carries one (flow #108). `--globoff` turns the whole feature off, so the one
      # URL gori resolved is the one URL curl fetches; with it, every line above sends exactly one
      # request for the literal target. Added only when a glob byte is present, so an ordinary
      # command keeps the shape a reader expects.
      #
      # It also fires on the one bracket that is legitimate — an IPv6 literal authority — and that
      # is harmless: curl parses the bracketed host before globbing, so `--globoff
      # \'http://[::1]:9143/p\'` puts `GET /p` / `Host: [::1]:9143` on the wire byte-identically
      # to the same command without the flag (measured against an AF_INET6 listener).
      private def self.globbed?(url : String) : Bool
        url.to_slice.any? { |b| b == 0x5b_u8 || b == 0x5d_u8 || b == 0x7b_u8 || b == 0x7d_u8 }
      end

      # The protocol flag for a capture whose request line says HTTP/2, else nil. curl
      # negotiates h2 over TLS through ALPN (`--http2`), but cleartext h2c has no negotiation
      # to do — it must be asserted up front, and `--http2` alone would send an h1 request to a
      # server that only speaks h2c. HTTP/1.x needs nothing: it is curl's default.
      private def self.version_flag(version : String, url : String) : String?
        return nil unless version.upcase == "HTTP/2"
        url.starts_with?("https://") ? "--http2" : "--http2-prior-knowledge"
      end

      # The body as a curl argument, or a named refusal. `shell_quote` carries ANY byte verbatim
      # inside '…' except one: 0x00. A shell command line is a NUL-terminated argv, so no quoting
      # can put a NUL into it — bash drops the byte and curl would send a body SHORTER than the
      # one gori captured, with nothing on the line saying so. A captured gRPC/protobuf body has
      # them routinely. So say it. The note is a `#` comment and `--data-raw` is the last part of
      # the command, so a paste still runs (sending no body) instead of sending a different one,
      # and the "Body" row of the same copy menu still hands over the exact bytes.
      private def self.data_argument(body : String) : String
        return "--data-raw #{shell_quote(body)}" unless body.to_slice.includes?(0_u8)
        "# body omitted: #{body.bytesize} bytes holding a NUL, which no shell argument can " \
        "carry; copy \"Body\" instead and pass it with --data-binary @FILE"
      end

      # --- the pure request primitives, shared with Tui::CopyMenu -------------------------

      # Split an HTTP message into {head, body} on the first blank line — CRLF wire
      # form first, bare-LF (an editor snapshot) as a fallback.
      def self.split_message(text : String) : {String, String}
        if idx = text.index("\r\n\r\n")
          {text[0, idx], text[(idx + 4)..]}
        elsif idx = text.index("\n\n")
          {text[0, idx], text[(idx + 2)..]}
        else
          {text, ""}
        end
      end

      # `head` split into lines on LF, each with one trailing CR dropped — what `split(/\r?\n/)`
      # spelled. Hand-rolled for two reasons, both about a head that is not valid UTF-8 (a
      # capture legitimately can be: obs-text in a header value, a latin-1 filename): a Regexp
      # over those bytes RAISES, which is why this used to `scrub` first — and that scrub then
      # REWROTE the operator's bytes, so a "Copy as cURL" `-H` came out carrying the three bytes
      # of U+FFFD where the wire had one. Byte-wise, neither happens.
      def self.split_lines(head : String) : Array(String)
        bytes = head.to_slice
        lines = [] of String
        start = 0
        i = 0
        while i < bytes.size
          if bytes[i] == 0x0a_u8
            stop = (i > start && bytes[i - 1] == 0x0d_u8) ? i - 1 : i
            lines << String.new(bytes[start, stop - start])
            start = i + 1
          end
          i += 1
        end
        lines << String.new(bytes[start, bytes.size - start])
        lines
      end

      # {method, request-target, version} from a request line, best-effort (missing
      # tokens come back empty rather than raising on a hand-typed partial request).
      #
      # BEST-EFFORT MEANS IT CAN MIS-SLICE, and callers must ask `request_line_refusal` first.
      # `split(' ')` takes `parts[1]` as the target, so a line whose SP framing is not
      # "METHOD SP target SP version" hands back a token that is not the target at all.
      def self.parse_request_line(line : String) : {String, String, String}
        parts = line.strip.split(' ')
        {parts[0]? || "", parts[1]? || "", parts[2]? || ""}
      end

      # WHY this request line cannot be framed as "METHOD SP request-target SP HTTP-version",
      # or nil when it can — the guard every "copy as <tool>" serializer owes the operator
      # before it builds a URL out of `parse_request_line`'s `parts[1]`.
      #
      # `Gori::FlowMapper` already refuses to STORE a derived target for these lines ("History
      # would render a deceptively-plausible-but-wrong URL") and keeps the verbatim request line
      # instead. The export surface re-parsed the raw head and produced exactly that URL, and
      # unlike History's honestly-broken row it produced a RUNNABLE one. Measured against a raw
      # listener, one `gori run show --format curl` each:
      #
      #   GET http://h/echo?a=b c&d=e HTTP/1.1   curl 'http://h/echo?a=b'      — query truncated
      #   GET  http://h/admin HTTP/1.1 (2 SP)    curl 'http://h'               — /admin gone
      #   GET<TAB>http://h/admin HTTP/1.1        curl 'http://h/HTTP/1.1'      — never requested
      #
      # python / fetch / Go / httpie / CSRF agreed with curl, `--format json|har|raw` kept the
      # bytes, and the runnable half was the wrong one. Doubled-space and tab request lines are
      # the shapes `Proxy::Codec::Http1` names as scope-gate bypass probes — the requests most
      # worth handing to a colleague, and the ones where a wrong URL is most expensive.
      #
      # A REFUSAL, not a lenient re-parse. `Proxy::Codec::Http1.gate_target` litigated the
      # lenient form for the forwarding path and rejected it: recovering a doubled-space
      # `GET  http://x/y HTTP/1.1` as method+target+version rebuilds it as `GET /y http://x/y`,
      # which is gori corrupting the operator's bytes (P7). There is no runnable equivalent of a
      # request line gori cannot frame, so — like `nul_url_note` — a paste does nothing instead
      # of doing the wrong thing.
      #
      # TOKEN COUNT is the discriminator, and the tab check is scoped to where a tab IMPLIES a
      # hidden delimiter, because a tab is not one:
      #
      #   > 3 tokens            unframable — an unencoded SP in the target, or a doubled SP
      #   <= 2 tokens + a HTAB  unframable — the tab stood where the delimiter belongs, so
      #                         `parts[1]` is the VERSION (or nothing) rather than the target
      #   exactly 3 tokens      framable, tab or no tab — `GET /a<TAB>b HTTP/1.1` frames
      #                         cleanly and that tab is the operator's payload (DESIGN.md §7),
      #                         which this must not refuse to export
      #   2 clean tokens        framable — `GET /p`, the hand-authored Repeater line
      #                         `parse_request_line`'s own doc reserves the tolerance for
      #
      # A ONE-token line (`GET` alone) resolves to the target base and is left alone here: it is
      # pre-existing, it is not a MIS-slice, and widening this guard to cover it would refuse
      # every keystroke of a request line being typed in a Repeater tab.
      def self.request_line_refusal(line : String) : String?
        trimmed = line.strip
        return nil if trimmed.empty?
        tokens = trimmed.split(' ')
        why = if tokens.size > 3
                "it splits into #{tokens.size} space-separated tokens, not the 3 that framing " \
                "needs (an unencoded space in the request-target, or a doubled one)"
              elsif tokens.size <= 2 && tokens.any?(&.includes?('\t'))
                "a TAB stands where a space delimiter belongs, and a tab does not delimit a " \
                "request line"
              end
        return nil unless why
        "the captured request line does not frame as \"METHOD SP request-target SP " \
        "HTTP-version\" — #{why}. Which of its tokens is the request-target is a guess, and a " \
        "wrong guess asks the origin for a different resource than the capture did. Read the " \
        "request line with --format raw"
      end

      # The full URL for the request: an absolute-form request target as-is, else the
      # target base joined with the origin-form path (falling back to the Host header
      # when no target base is set — a hand-authored request). "" when unresolvable.
      def self.resolve_url(req_target : String, target : String, header_lines : Array(String)) : String
        # Case-insensitive via the one home: an `HTTP://acme.test/x` target used to fall
        # through and get a base prefixed, yielding `https://acme.test/HTTP://acme.test/x`
        # on the operator's clipboard.
        return req_target if Gori::Url.absolute_form?(req_target)
        base = authority_base(target.strip)
        if base.empty?
          host = header_value(header_lines, "host")
          base = host ? "http://#{host}" : ""
        end
        return "" if base.empty?
        base = base.rstrip('/')
        return base if req_target.empty? || req_target == "*"
        req_target.starts_with?('/') ? "#{base}#{req_target}" : "#{base}/#{req_target}"
      end

      # scheme://host[:port] with any path/query the user may have pasted into the target
      # field stripped — the send path (FlowRequest.parse_target) uses only scheme/host/port,
      # so the copied URL must too, else it doubles the request-line path onto the target's.
      private def self.authority_base(target : String) : String
        sep = target.index("://")
        return target unless sep
        slash = target.index('/', sep + 3)
        slash ? target[0, slash] : target
      end

      # The first matching header's value (case-insensitive name), or nil.
      def self.header_value(header_lines : Array(String), name : String) : String?
        want = name.downcase
        each_header(header_lines) { |hname, value| return value if hname.downcase == want }
        nil
      end

      # Yield each header FIELD as {stripped name, stripped value}, obs-fold continuations folded
      # into the field they continue. Lines with no colon that are not continuations (a blank
      # line, a partial paste) are skipped. ONE parse convention shared by `command`, the copy
      # menu's Cookie row and the wscat builder, so they can't drift.
      #
      # The fold is the whole point. RFC 9112 §5.2 makes a line whose first byte is SP or HTAB
      # part of the PREVIOUS field's value, and this used to `strip` the name — which made a
      # continuation that happens to carry a colon indistinguishable from a header of its own:
      #
      #   X-Long: part1        ->  -H 'X-Long: part1'    the real value, TRUNCATED
      #     X-Fake: part2      ->  -H 'X-Fake: part2'    a header the wire never carried
      #
      # …while `--format json`, whose parser does NOT strip the name, reported the same head as
      # `X-Long` plus `"  X-Fake"`. Three surfaces, three header sets, for one message. gori is
      # the tool an operator points at header-parsing differences; the command it hands them must
      # not have one of its own. Folded here into `part1 part2` — obs-fold replaced by one SP,
      # which is what a recipient that accepts one is required to do.
      def self.each_header(header_lines : Array(String), & : String, String ->) : Nil
        name = nil.as(String?)
        value = ""
        header_lines.each do |line|
          if fold_line?(line)
            # An ORPHAN fold — a continuation with no field above it (a head that starts with
            # one) — continues nothing and is not a field either, so it is dropped rather than
            # promoted to a header.
            if name
              cont = line.strip
              value = value.empty? ? cont : "#{value} #{cont}" unless cont.empty?
            end
            next
          end
          if n = name
            yield n, value
            name = nil
          end
          fname, sep, fvalue = line.partition(":")
          next if sep.empty?
          fname = fname.strip
          next if fname.empty?
          name = fname
          value = fvalue.strip
        end
        if n = name
          yield n, value
        end
      end

      # An obs-fold continuation line: its first BYTE is SP or HTAB. Byte-wise rather than
      # `starts_with?(' ')` for the reason `split_lines` is byte-wise — a captured header line
      # need not be valid UTF-8, and char iteration answers about U+FFFD instead of the byte.
      private def self.fold_line?(line : String) : Bool
        return false if line.empty?
        b = line.to_slice[0]
        b == 0x20_u8 || b == 0x09_u8
      end

      # POSIX single-quote: wrap in '…' and rewrite each embedded ' as '\'' so the
      # result is one safe shell word regardless of what's inside (incl. newlines).
      #
      # BYTE SAFETY — this was `s.gsub("'", "'\\''")`. `String#gsub(String, String)` delegates to
      # the CHAR overload as soon as the needle is ONE BYTE long, and Crystal's char iteration
      # substitutes the three bytes of U+FFFD for every byte that is not valid UTF-8. `s` here is
      # a CAPTURE — `--data-raw` gets the request body straight off the wire — so "Copy as cURL"
      # of a binary body handed the operator a command that did not reproduce the request.
      # Measured on body `a='x'&bin=<ff fe 01 02>`:
      #
      #   before  … 26 62 69 6e 3d ef bf bd ef bf bd 01 02   4 captured bytes → 8
      #   after   … 26 62 69 6e 3d ff fe 01 02               intact
      #
      # Scanning and splicing BYTES is the rule `Fuzz::Plan.wrap_token` already writes down.
      def self.shell_quote(s : String) : String
        bytes = s.to_slice
        io = IO::Memory.new(bytes.size + 2)
        io << '\''
        bytes.each do |b|
          if b == 0x27_u8 # '
            io << "'\\''"
          else
            io.write_byte(b)
          end
        end
        io << '\''
        String.new(io.to_slice)
      end
    end
  end
end
