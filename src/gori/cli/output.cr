require "json"
require "../store"
require "../url"
require "../fuzz"
require "../miner"
require "../sequencer"
require "../discover"
require "../sitemap"
require "../probe/group"
require "../notes"
require "../jwt"

module Gori
  module CLI
    # TUI-free output formatting shared by `gori run` and the headless capture
    # printer. Pure functions over Store read-models → Strings; no terminal, no
    # colour. The JSON shape here is the stable, documented contract for scripts.
    module Output
      # One JSON object (one line, for JSON-Lines streams) describing a flow row.
      def self.flow_row_json(row : Store::FlowRow) : String
        JSON.build { |j| flow_row_fields(j, row) }
      end

      # Emits the flow-row fields into an open builder (reused by `show`, which
      # nests the row alongside the bodies).
      def self.flow_row_fields(j : JSON::Builder, row : Store::FlowRow) : Nil
        j.object do
          j.field "id", row.id
          j.field "created_at", row.created_at
          j.field "time", iso_time(row.created_at)
          j.field "scheme", row.scheme
          j.field "method", row.method
          j.field "host", row.host
          j.field "port", row.port
          j.field "target", row.target
          j.field "status", row.status
          j.field "state", row.state.to_s.downcase
          j.field "size", row.size
          j.field "response_size", row.response_size
          j.field "duration_us", row.duration_us
          j.field "content_type", row.content_type
          # Kept in lockstep with MCP::Serialize.flow_row (spec/cli/run/history_spec.cr pins
          # the two key sets against each other): a consumer of either feed has no other way
          # to tell a gori-authored stub response from one the origin actually sent (#511).
          j.field "short_circuited", row.short_circuited?
          # What gori has to say about this flow that its bytes cannot (`FlowRow#advisory`):
          # a rule that structurally could not run on it, a request the ORIGIN invented in a
          # PUSH_PROMISE. Emitted only when there is one, so a script keying off field
          # presence is not broken by a field it never asked for — the same discipline
          # `emit_ws_shape_json` uses.
          advisories = row.advisories
          unless advisories.empty?
            j.field("advisory") { j.array { advisories.each { |l| j.string(term_safe(l)) } } }
          end
        end
      end

      # Neutralize terminal control bytes in an untrusted CAPTURED string before it is
      # printed to a live terminal. A malicious client can embed ANSI/OSC escape
      # sequences in its request line (method / host / target), which `puts` would
      # otherwise inject verbatim into the operator's terminal (and re-inject on every
      # later view). Replace every control char (incl. ESC, CR/LF, tab, C1) with '·'.
      #
      # Also scrubs invalid UTF-8 first: a captured host/path is raw bytes off the wire
      # (see Sitemap.template_class's comment) and can be invalid UTF-8 without containing
      # a single control byte, which JSON::Builder does NOT validate — the sitemap JSON/text/
      # paths exports all route through this, so an unscrubbed value here reaches STDOUT as
      # invalid UTF-8. `.scrub` is a no-op (returns self, no allocation) on the common
      # valid-UTF-8 case, so this stays free when there's nothing to fix.
      def self.term_safe(s : String) : String
        s = s.scrub
        return s unless s.each_char.any?(&.control?)
        String.build { |io| s.each_char { |c| io << (c.control? ? '·' : c) } }
      end

      # Like `term_safe` but preserves '\n'/'\t', so a captured multi-line head/body keeps
      # its layout while ANSI/OSC/CSI escapes and other control bytes are neutralized. Use
      # for captured text written to a live terminal (the `show`/`repeater` text views).
      # `--format raw` stays the exact-bytes path for scripts/redirection.
      def self.term_safe_multiline(s : String) : String
        s = s.scrub
        return s unless s.each_char.any? { |c| c.control? && c != '\n' && c != '\t' }
        String.build { |io| s.each_char { |c| io << ((c.control? && c != '\n' && c != '\t') ? '·' : c) } }
      end

      # A WebSocket message's frame shape, as a bracketed note, EMPTY when there is nothing
      # unusual to say. Silence is the point for the ordinary case: annotating every TEXT
      # frame with `[TEXT fin=1 rsv=0]` would bury the one line that is not ordinary. A
      # control frame always names itself, because until V7 it did not appear at all.
      def self.ws_shape_note(m : Store::WsMessage) : String
        s = m.shape
        parts = [] of String
        parts << (Store::WsOutMessage::OPCODE_NAMES[m.opcode]? || "op#{m.opcode}") if m.control?
        parts << "fin=0" unless s.fin
        parts << "rsv=#{s.rsv}" if s.rsv != 0
        parts << "UNMASKED" if s.masked == false && m.direction == "out"
        parts << "#{s.frames} frames" if s.frames > 1
        parts.empty? ? "" : "[#{parts.join(' ')}]"
      end

      # The part of a control frame worth reading: a CLOSE's code and reason, a ping/pong's
      # payload. This is the diagnostic that existed nowhere on the proxy path.
      def self.ws_control_detail(m : Store::WsMessage) : String
        if code = m.close_code
          reason = m.close_reason.try { |r| String.new(r).scrub }
          return reason && !reason.empty? ? "#{code} #{term_safe(reason)}" : code.to_s
        end
        return "(no payload)" if m.payload.empty?
        body = String.new(m.payload)
        body.valid_encoding? ? term_safe(body) : "0x#{m.payload.hexstring}"
      end

      # The shape fields, for a JSON reader. Only what departs from the default is emitted,
      # so an ordinary message's object is exactly the shape it was before V7 — a script
      # keying off field presence is not broken by a feature it did not ask for.
      def self.emit_ws_shape_json(j : JSON::Builder, m : Store::WsMessage) : Nil
        s = m.shape
        j.field "fin", false unless s.fin
        j.field "rsv", s.rsv if s.rsv != 0
        s.masked.try { |mk| j.field "masked", mk unless mk }
        j.field "frames", s.frames if s.frames > 1
        m.close_code.try { |c| j.field "close_code", c }
        m.close_reason.try { |r| j.field "close_reason", String.new(r).scrub }
      end

      # "#42  GET   https  example.com:443/users  200  1.2kB  3ms  [Complete]"
      # Columns are padded for scannability; status/state make capture progress legible.
      def self.flow_row_text(row : Store::FlowRow) : String
        status = row.status.try(&.to_s) || "—"
        # HTTP proxied requests store an absolute-form target ("http://host/path") that
        # already carries the host; only origin-form targets need the host prefixed.
        # `Gori::Url.location`, not the `target.starts_with?("http")` spelled out here before:
        # that is not the absolute-form test (RFC 3986 §3.1 — schemes are case-insensitive),
        # so a captured `GET HTTP://host/x` printed as `127.0.0.1HTTP://127.0.0.1:19594/upper`.
        loc = term_safe(Gori::Url.location(row.host, row.target))
        dur = row.duration_us.try { |us| " #{human_us(us)}" } || ""
        String.build do |io|
          io << '#' << row.id.to_s.ljust(6)
          io << term_safe(row.method).ljust(7)
          io << term_safe(row.scheme).ljust(6)
          io << loc
          io << "  -> " << status
          io << "  " << human_size(row.size)
          io << dur
          # Never silently: a text-mode reader scanning this list would otherwise take a
          # stub for traffic the server produced.
          io << "  [stub]" if row.short_circuited?
          # Same reasoning as [stub] one line up: a text-mode reader scanning a list must be
          # able to SEE that gori has something to say about a row. The chip is a pointer —
          # `gori run show <id>` prints the sentences.
          io << "  [!]" unless row.advisories.empty?
          io << "  [" << row.state << ']' unless row.state.complete?
        end
      end

      # --- fuzz result rows ---------------------------------------------------

      def self.fuzz_row_json(r : Fuzz::Result) : String
        JSON.build { |j| fuzz_row_fields(j, r) }
      end

      def self.fuzz_array_json(results : Array(Fuzz::Result)) : String
        JSON.build { |j| j.array { results.each { |r| fuzz_row_fields(j, r) } } }
      end

      def self.fuzz_row_fields(j : JSON::Builder, r : Fuzz::Result) : Nil
        j.object do
          j.field "index", r.index
          # `.scrub`: a `Fuzz::Payload` is byte-faithful, so a wordlist entry may be invalid
          # UTF-8 (a raw `\xff\xfe` bad-strings payload). `JSON::Builder#string` escapes JSON
          # metacharacters but passes raw bytes straight through, so one such payload used to
          # produce a document no JSON parser would accept — poisoning EVERY row, not just its
          # own. Scrubbing to U+FFFD matches the MCP emitter (`Serialize.text`) and keeps the
          # report parseable; the exact bytes that went out are recoverable from `request`.
          j.field("payloads") { j.array { r.payloads.each { |p| j.string(p.scrub) } } }
          j.field "position", r.position
          j.field "status", r.status
          j.field "length", r.length
          j.field "words", r.words
          j.field "lines", r.lines
          j.field "duration_us", r.duration_us
          j.field "matched", r.matched?
          j.field "error", r.error
          # A declared `¦chain` that could not run on this payload — the payload went out
          # UNTRANSFORMED. Emitted (and only when set) so a script never reads `"error":null`
          # for a request that sent a different test than the operator asked for. `.scrub` for
          # the same reason `payloads` is scrubbed: a codec's refusal can quote a byte from the
          # payload, and one invalid byte would poison the whole document.
          if ce = r.chain_error
            j.field "chain_error", ce.scrub
          end
          # The gRPC CALL's outcome. `status` is 200 for EVERY gRPC response, so without these
          # a sweep against an origin denying every call was byte-identical to one against an
          # origin allowing them all. Emitted only when the response actually carried them, so
          # a non-gRPC run's JSON is unchanged. `.scrub`: `grpc-message` is origin-chosen text.
          if gs = r.grpc_status
            j.field "grpc_status", gs
            j.field "grpc_status_name", Proxy::H2::Grpc.status_name(gs)
          end
          if gm = r.grpc_message
            j.field "grpc_message", gm.scrub
          end
          j.field "extracted", r.extracted
          # Only when true. This is an exception rather than a per-row property, and a `false`
          # on every row of every clean run would bury the one row that matters.
          j.field "retried", true if r.retried?
        end
      end

      # --- miner finding rows -------------------------------------------------

      def self.mine_row_json(f : Miner::Finding) : String
        JSON.build { |j| mine_finding_fields(j, f) }
      end

      def self.mine_array_json(findings : Array(Miner::Finding)) : String
        JSON.build { |j| j.array { findings.each { |f| mine_finding_fields(j, f) } } }
      end

      def self.mine_finding_fields(j : JSON::Builder, f : Miner::Finding) : Nil
        j.object do
          j.field "name", f.name
          j.field "location", f.location.label
          j.field "evidence", f.evidence.label
          j.field "confidence", f.confidence.label
          j.field "canary", f.canary
          j.field "status", f.status
          j.field "delta", f.delta
          # The gRPC CALL's outcome. `status` above is 200 for every gRPC response, so without
          # these a mine against a target denying every candidate was byte-identical to one
          # allowing them all. Emitted only when the confirming round carried them, so a
          # non-gRPC run's JSON is unchanged. `.scrub`: `grpc-message` is origin-chosen text.
          if gs = f.grpc_status
            j.field "grpc_status", gs
            j.field "grpc_status_name", Proxy::H2::Grpc.status_name(gs)
          end
          if gm = f.grpc_message
            j.field "grpc_message", gm.scrub
          end
        end
      end

      # "[+] debug                 query    · length"
      def self.mine_row_text(f : Miner::Finding) : String
        String.build do |io|
          io << (f.confidence.confirmed? ? "[+] " : "[?] ")
          io << f.name.ljust(24)
          io << "  " << f.location.label.ljust(9)
          io << "· " << f.evidence.label
          if gs = f.grpc_status
            io << "  grpc " << gs << ' ' << Proxy::H2::Grpc.status_name(gs)
            io << " · " << f.grpc_message if f.grpc_message
          end
        end
      end

      # --- jwt workbench (decode / re-sign / attack payloads) -----------------
      # JSON shapes live in the engine (jwt/present.cr) so `gori run jwt` and the MCP
      # jwt_* tools stay byte-identical; the text formatter below is CLI-only.

      # "[none]     alg=none            unsigned; accepted if …"
      def self.jwt_attack_text(a : Jwt::Attack) : String
        String.build do |io|
          io << "[" << a.category << "]"
          io << " " * {12 - a.category.size - 2, 1}.max
          io << a.name.ljust(24) << "  " << a.note << "\n"
          io << "  " << a.token
        end
      end

      # --- sequencer samples (jsonl stream) -----------------------------------

      def self.sequence_sample_json(s : Sequencer::Sample) : String
        JSON.build do |j|
          j.object do
            j.field "index", s.index
            j.field "status", s.status
            j.field "token", s.token
            j.field "length", s.length
            j.field "error", s.error
            # The gRPC CALL's outcome. `status` above is 200 for every gRPC response, so
            # without these a collection against a target denying every call read as healthy.
            # Emitted only when the response actually carried them, so a non-gRPC sample's
            # JSON line is unchanged. `.scrub`: `grpc-message` is origin-chosen text.
            if gs = s.grpc_status
              j.field "grpc_status", gs
              j.field "grpc_status_name", Proxy::H2::Grpc.status_name(gs)
            end
            if gm = s.grpc_message
              j.field "grpc_message", gm.scrub
            end
          end
        end
      end

      # --- discover findings --------------------------------------------------

      def self.discover_row_json(f : Discover::Finding) : String
        JSON.build { |j| discover_finding_fields(j, f) }
      end

      def self.discover_array_json(findings : Array(Discover::Finding)) : String
        JSON.build { |j| j.array { findings.each { |f| discover_finding_fields(j, f) } } }
      end

      def self.discover_finding_fields(j : JSON::Builder, f : Discover::Finding) : Nil
        j.object do
          j.field "url", f.url
          j.field "method", f.method
          j.field "status", f.status
          j.field "length", f.length
          j.field "content_type", f.content_type
          j.field "source", f.source.label
          j.field "depth", f.depth
          j.field "confidence", f.confidence.round(2)
        end
      end

      # "200  GET  http://h/admin  (bruteforced 0.92)"
      def self.discover_row_text(f : Discover::Finding) : String
        String.build do |io|
          io << (f.status.try(&.to_s.ljust(3)) || "---")
          io << "  " << f.method.ljust(4)
          io << " " << f.url
          io << "  (" << f.source.label << " " << f.confidence.round(2) << ")"
        end
      end

      # --- probe scan issues --------------------------------------------------

      def self.probe_group_json(g : Probe::Group) : String
        JSON.build { |j| probe_group_fields(j, g) }
      end

      def self.probe_array_json(groups : Array(Probe::Group)) : String
        JSON.build { |j| j.array { groups.each { |g| probe_group_fields(j, g) } } }
      end

      def self.probe_group_fields(j : JSON::Builder, g : Probe::Group) : Nil
        Probe.group_json(j, g) # shared field shape (also used by the MCP probe_scan tool)
      end

      # "[high]      secret_in_url             api.test   ×3   token"
      # plus an indented representative affected URL ("(+N more)" when capped).
      def self.probe_group_text(g : Probe::Group) : String
        String.build do |io|
          io << "[#{g.severity.label}]".ljust(11)
          io << g.code.ljust(28)
          io << "  " << term_safe(g.host)
          io << "  ×" << g.hit_count
          if ev = g.evidence
            io << "  " << term_safe(ev)
          end
          if first = g.affected.first?
            io << "\n    " << term_safe(first)
            more = g.affected.size - 1
            io << " (+#{more} more)" if more > 0
          end
        end
      end

      # --- persisted probe findings (triage) ----------------------------------

      def self.probe_issue_array_json(issues : Array(Store::ProbeIssue)) : String
        JSON.build { |j| j.array { issues.each { |i| Probe.issue_json(j, i) } } }
      end

      # "12   [high]      secret_in_url   api.test   ×3   open   token"
      # Leads with the id, because every triage subcommand addresses a finding by it.
      def self.probe_issue_text(i : Store::ProbeIssue) : String
        String.build do |io|
          io << i.id.to_s.ljust(5)
          io << "[#{i.severity.label}]".ljust(11)
          io << i.code.ljust(28)
          io << "  " << term_safe(i.host)
          io << "  ×" << i.hit_count
          io << "  " << i.status.label
          if ev = i.evidence
            io << "  " << term_safe(ev)
          end
        end
      end

      # --- scan rule catalog --------------------------------------------------

      # "[on ] passive  secret_in_url    Secret in URL          infoleak"
      # A disabled rule reads "[off]" so the state is scannable down the left edge.
      def self.probe_rule_text(e : Probe::RuleCatalog::Entry) : String
        String.build do |io|
          io << (e.enabled ? "[on ] " : "[off] ")
          io << e.kind.ljust(8)
          io << term_safe(e.id).ljust(26)
          io << "  " << term_safe(e.name).ljust(30)
          io << "  " << e.category
          if est = e.estimate
            io << " · " << est
          end
          if e.kind == "custom"
            io << " · " << (e.scope == "global" ? "GLOBAL" : "PROJECT")
            io << " · " << e.side << "/" << e.region << " · " << e.match_kind
          end
        end
      end

      # "#0     admin                 200   1.2kB     142w    31ms"
      def self.fuzz_row_text(r : Fuzz::Result) : String
        String.build do |io|
          io << '#' << r.index.to_s.ljust(6)
          io << r.payloads.join(", ").ljust(24)
          io << "  " << (r.status.try(&.to_s) || (r.error ? "ERR" : "—")).ljust(4)
          io << "  " << human_size(r.length).ljust(8)
          io << "  " << "#{r.words}w".ljust(7)
          io << "  " << human_us(r.duration_us)
          # For a gRPC target the 200 to the left is a constant; THIS is the call's outcome.
          # Only rendered when the response carried it, so a non-gRPC row is unchanged.
          if gs = r.grpc_status
            io << "  grpc " << gs << ' ' << Proxy::H2::Grpc.status_name(gs)
            io << " · " << r.grpc_message if r.grpc_message
          end
          io << "  ⟦" << r.extracted << '⟧' if r.extracted
          # Before the error text, because it qualifies the SEND rather than the response: this
          # request went out twice (see `Fuzz::Result#retried?`).
          io << "  re-sent" if r.retried?
          io << "  " << r.error if r.error
          # The transform declared for this payload did not run; the payload went out raw.
          io << "  ⚠ " << r.chain_error if r.chain_error
        end
      end

      # --- notes --------------------------------------------------------------

      # Title shown in listings: the note's first non-blank line, or a positional
      # fallback for a blank note (mirrors the TUI sub-tab's "note N").
      def self.note_label(idx : Int32, text : String) : String
        Notes.title(text) || "note #{idx + 1}"
      end

      # "* 1  title  (12 lines, 340B)" — 1-based index, '*' marks the active note.
      def self.note_row_text(idx : Int32, text : String, current : Bool) : String
        lines = Notes.line_count(text)
        String.build do |io|
          io << (current ? '*' : ' ') << ' '
          io << (idx + 1) << "  " << note_label(idx, text)
          io << "  (" << lines << (lines == 1 ? " line, " : " lines, ") << human_size(text.bytesize.to_i64) << ')'
        end
      end

      # The whole note set as a JSON array. `with_text` adds each note's full body
      # (the `--all` view); without it the array is a summary (the listing view).
      def self.notes_array_json(doc : Notes::Doc, with_text : Bool) : String
        JSON.build do |j|
          j.array do
            doc.notes.each_with_index do |entry, i|
              note_object_fields(j, i, entry, current: doc.cur == i, with_text: with_text)
            end
          end
        end
      end

      # One note as a standalone JSON object (the `show <n>` view).
      def self.note_object_json(idx : Int32, entry : Notes::NoteEntry, current : Bool, with_text : Bool) : String
        JSON.build { |j| note_object_fields(j, idx, entry, current: current, with_text: with_text) }
      end

      def self.note_object_fields(j : JSON::Builder, idx : Int32, entry : Notes::NoteEntry, current : Bool, with_text : Bool) : Nil
        text = entry.text
        j.object do
          j.field "id", entry.id
          j.field "index", idx + 1
          j.field "title", Notes.title(text)
          j.field "lines", Notes.line_count(text)
          j.field "bytes", text.bytesize
          j.field "current", current
          j.field "text", text if with_text
        end
      end

      # --- sitemap tree -------------------------------------------------------

      # The host → path endpoint tree as an indented `tree(1)`-style listing. Each
      # host is a root (with its endpoint count); children draw ├─/└─ guides. An
      # endpoint node shows its method set, a folded numeric run its value count, and
      # a path tag is appended as "# memo". Hosts are separated by a blank line. Empty
      # input → "" (the caller prints an empty-state to STDERR instead).
      def self.sitemap_text(hosts : Array(Sitemap::Node)) : String
        String.build do |io|
          hosts.each_with_index do |host, i|
            io << '\n' if i > 0
            io << term_safe(host.label)
            io << "  (" << sitemap_path_count(host.endpoints) << ')' if host.endpoints > 0
            io << '\n'
            sitemap_text_children(host, "", io)
          end
        end
      end

      private def self.sitemap_text_children(node : Sitemap::Node, prefix : String, io : IO) : Nil
        last = node.children.size - 1
        node.children.each_with_index do |child, i|
          io << prefix << (i == last ? "└─ " : "├─ ")
          sitemap_node_label(child, io)
          io << '\n'
          # A folded numeric group renders collapsed (its values stay in the chip),
          # matching the TUI default. An ID fold instead descends into ONE representative
          # child, so route structure BELOW the id (/users/{uuid}/orders) survives — the
          # ids are noise, but what hangs off them is the report's whole point.
          nested = prefix + (i == last ? "   " : "│  ")
          if child.template?
            rep = child.children.find { |c| !c.children.empty? }
            sitemap_text_children(rep, nested, io) if rep
          elsif !child.grouped
            sitemap_text_children(child, nested, io)
          end
        end
      end

      private def self.sitemap_node_label(node : Sitemap::Node, io : IO) : Nil
        io << term_safe(node.label)
        if node.grouped
          io << "  (" << node.children.size << " values)"
          # The verbs the fold stands in for, so a collapsed row still reads as an endpoint.
          io << "  [" << term_safe(node.fold_methods.join(' ')) << ']' unless node.fold_methods.empty?
        elsif !node.methods.empty?
          io << "  [" << term_safe(node.methods.join(' ')) << ']'
        end
        if t = node.tag
          io << "  # " << term_safe(t)
        end
      end

      private def self.sitemap_path_count(n : Int32) : String
        n == 1 ? "1 path" : "#{n} paths"
      end

      # Flat endpoint listing — one line per (host, path) with its comma-joined method
      # set, e.g. "GET,POST  acme.test/api/users". Pipe/grep-friendly; numeric folding
      # is irrelevant here (every endpoint is listed, even folded ones). Empty → "".
      def self.sitemap_paths(hosts : Array(Sitemap::Node)) : String
        String.build do |io|
          hosts.each { |host| sitemap_host_paths(host, host.label, io) }
        end
      end

      private def self.sitemap_host_paths(node : Sitemap::Node, host : String, io : IO) : Nil
        io << term_safe(node.methods.join(',')) << "  " << term_safe(host) << term_safe(node.path) << '\n' unless node.methods.empty?
        node.children.each { |c| sitemap_host_paths(c, host, io) }
      end

      # The endpoint tree as JSON: an array of host objects, each `{host, endpoints,
      # tag?, children}`. A child node is `{label, path, methods?, tag?, children?}`,
      # or for a synthetic fold `{label, grouped:true, template?, methods?, children}` — a
      # fold has no path, `template` ("{uuid}"/"{hex}"/"{date}") marks an ID fold as opposed
      # to a numeric run, and its `methods` are the UNION of its children's verbs. The stable, documented machine contract. Unlike the text tree
      # (which collapses a numeric fold and shows one representative under an ID fold),
      # JSON always keeps every child nested — the complete tree, with `grouped` as the
      # hint so a consumer can collapse it itself.
      #
      # Emitted by hand to an IO rather than through JSON::Builder: the tree nests one
      # object + one "children" array per path segment (~2 JSON levels each), and
      # JSON::Builder hard-caps nesting at 100, so a captured path ~45 segments deep tore
      # the whole report down with `JSON::Error: Nesting of 100 is too deep`. A security
      # tool must not silently truncate the endpoint tree, so we drop the artificial
      # ceiling instead — String#to_json still does every value's escaping, so the bytes
      # are identical to what the builder produced for shallow trees.
      def self.sitemap_json(hosts : Array(Sitemap::Node)) : String
        String.build do |io|
          io << '['
          hosts.each_with_index do |h, i|
            io << ',' if i > 0
            sitemap_host_json(io, h)
          end
          io << ']'
        end
      end

      private def self.sitemap_host_json(io : IO, host : Sitemap::Node) : Nil
        io << '{'
        # host.label/tag are captured/user data and can be invalid UTF-8 (see
        # Sitemap.template_class) — term_safe scrubs that (and strips control bytes),
        # so this stays valid UTF-8 JSON like the text/paths formats already are.
        io << %("host":)
        term_safe(host.label).to_json(io)
        io << %(,"endpoints":)
        host.endpoints.to_json(io)
        if t = host.tag
          io << %(,"tag":)
          term_safe(t).to_json(io)
        end
        sitemap_children_json(io, host)
        io << '}'
      end

      private def self.sitemap_node_json(io : IO, node : Sitemap::Node) : Nil
        io << '{'
        io << %("label":)
        term_safe(node.label).to_json(io)
        # A fold is synthetic — its `path` is always "" and carries no meaning, so it is
        # omitted rather than emitted as an empty string. `template` names the id class
        # so a consumer can tell an id fold from a numeric run without parsing labels.
        if node.grouped
          io << %(,"grouped":true)
          if node.template? # one of TEMPLATE_LABELS: always plain ASCII
            io << %(,"template":)
            node.label.to_json(io)
          end
        else
          io << %(,"path":)
          term_safe(node.path).to_json(io)
        end
        # On a fold these are the union of its children's verbs, not its own.
        verbs = node.grouped ? node.fold_methods : node.methods
        unless verbs.empty?
          io << %(,"methods":[)
          verbs.each_with_index do |m, i|
            io << ',' if i > 0
            term_safe(m).to_json(io)
          end
          io << ']'
        end
        if t = node.tag
          io << %(,"tag":)
          term_safe(t).to_json(io)
        end
        sitemap_children_json(io, node)
        io << '}'
      end

      private def self.sitemap_children_json(io : IO, node : Sitemap::Node) : Nil
        return if node.children.empty?
        io << %(,"children":[)
        node.children.each_with_index do |c, i|
          io << ',' if i > 0
          sitemap_node_json(io, c)
        end
        io << ']'
      end

      def self.human_size(bytes : Int64) : String
        return "#{bytes}B" if bytes < 1024
        kb = bytes / 1024.0
        return "#{round1(kb)}kB" if kb < 1024
        mb = kb / 1024.0
        return "#{round1(mb)}MB" if mb < 1024
        gb = mb / 1024.0
        return "#{round1(gb)}GB" if gb < 1024
        "#{round1(gb / 1024.0)}TB"
      end

      def self.human_us(micros : Int64) : String
        return "#{micros}µs" if micros < 1000
        ms = micros / 1000.0
        return "#{round1(ms)}ms" if ms < 1000
        "#{round1(ms / 1000.0)}s"
      end

      # Local ISO-8601 from unix micros (the store's created_at unit).
      def self.iso_time(micros : Int64) : String
        Time.unix(micros // 1_000_000).to_local.to_s("%Y-%m-%dT%H:%M:%S%:z")
      end

      private def self.round1(n : Float64) : String
        ((n * 10).round / 10.0).to_s
      end
    end
  end
end
