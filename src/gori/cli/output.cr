require "json"
require "../store"
require "../fuzz"
require "../miner"
require "../sitemap"
require "../prism/group"
require "../notes"

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
        end
      end

      # Neutralize terminal control bytes in an untrusted CAPTURED string before it is
      # printed to a live terminal. A malicious client can embed ANSI/OSC escape
      # sequences in its request line (method / host / target), which `puts` would
      # otherwise inject verbatim into the operator's terminal (and re-inject on every
      # later view). Replace every control char (incl. ESC, CR/LF, tab, C1) with '·'.
      def self.term_safe(s : String) : String
        return s unless s.each_char.any?(&.control?)
        String.build { |io| s.each_char { |c| io << (c.control? ? '·' : c) } }
      end

      # "#42  GET   https  example.com:443/users  200  1.2kB  3ms  [Complete]"
      # Columns are padded for scannability; status/state make capture progress legible.
      def self.flow_row_text(row : Store::FlowRow) : String
        status = row.status.try(&.to_s) || "—"
        # HTTP proxied requests store an absolute-form target ("http://host/path")
        # that already carries the host; only origin-form targets need host prefixed.
        loc = term_safe(row.target.starts_with?("http") ? row.target : "#{row.host}#{row.target}")
        dur = row.duration_us.try { |us| " #{human_us(us)}" } || ""
        String.build do |io|
          io << '#' << row.id.to_s.ljust(6)
          io << term_safe(row.method).ljust(7)
          io << term_safe(row.scheme).ljust(6)
          io << loc
          io << "  -> " << status
          io << "  " << human_size(row.size)
          io << dur
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
          j.field("payloads") { j.array { r.payloads.each { |p| j.string(p) } } }
          j.field "position", r.position
          j.field "status", r.status
          j.field "length", r.length
          j.field "words", r.words
          j.field "lines", r.lines
          j.field "duration_us", r.duration_us
          j.field "matched", r.matched?
          j.field "error", r.error
          j.field "extracted", r.extracted
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
        end
      end

      # "[+] debug                 query    · length"
      def self.mine_row_text(f : Miner::Finding) : String
        String.build do |io|
          io << (f.confidence.confirmed? ? "[+] " : "[?] ")
          io << f.name.ljust(24)
          io << "  " << f.location.label.ljust(8)
          io << "· " << f.evidence.label
        end
      end

      # --- prism scan issues --------------------------------------------------

      def self.prism_group_json(g : Prism::Group) : String
        JSON.build { |j| prism_group_fields(j, g) }
      end

      def self.prism_array_json(groups : Array(Prism::Group)) : String
        JSON.build { |j| j.array { groups.each { |g| prism_group_fields(j, g) } } }
      end

      def self.prism_group_fields(j : JSON::Builder, g : Prism::Group) : Nil
        j.object do
          j.field "code", g.code
          j.field "category", g.category
          j.field "host", g.host
          j.field "title", g.title
          j.field "severity", g.severity.label
          j.field "hit_count", g.hit_count
          j.field("affected") { j.array { g.affected.each { |u| j.string(u) } } }
          j.field "affected_count", g.affected.size
          j.field "evidence", g.evidence
          j.field "sample_flow_id", g.sample_flow_id
          j.field "sample_replay_id", g.sample_replay_id
          j.field "remediation", Prism.remediation(g.code)
        end
      end

      # "[high]      secret_in_url             api.test   ×3   token"
      # plus an indented representative affected URL ("(+N more)" when capped).
      def self.prism_group_text(g : Prism::Group) : String
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

      # "#0     admin                 200   1.2kB     142w    31ms"
      def self.fuzz_row_text(r : Fuzz::Result) : String
        String.build do |io|
          io << '#' << r.index.to_s.ljust(6)
          io << r.payloads.join(", ").ljust(24)
          io << "  " << (r.status.try(&.to_s) || (r.error ? "ERR" : "—")).ljust(4)
          io << "  " << human_size(r.length).ljust(8)
          io << "  " << "#{r.words}w".ljust(7)
          io << "  " << human_us(r.duration_us)
          io << "  ⟦" << r.extracted << '⟧' if r.extracted
          io << "  " << r.error if r.error
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
          # matching the TUI default; descend into every other node.
          sitemap_text_children(child, prefix + (i == last ? "   " : "│  "), io) unless child.grouped
        end
      end

      private def self.sitemap_node_label(node : Sitemap::Node, io : IO) : Nil
        io << term_safe(node.label)
        if node.grouped
          io << "  (" << node.children.size << " values)"
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
      # tag?, children}`. A child node is `{label, path, methods?, grouped?, tag?,
      # children?}`. The stable, documented machine contract. Unlike the text tree
      # (which renders a folded `grouped` node collapsed), JSON keeps the fold's
      # children nested under it — the complete tree, with `grouped:true` as the hint
      # so a consumer can collapse them itself.
      def self.sitemap_json(hosts : Array(Sitemap::Node)) : String
        JSON.build do |j|
          j.array { hosts.each { |h| sitemap_host_json(j, h) } }
        end
      end

      private def self.sitemap_host_json(j : JSON::Builder, host : Sitemap::Node) : Nil
        j.object do
          j.field "host", host.label
          j.field "endpoints", host.endpoints
          if t = host.tag
            j.field "tag", t
          end
          sitemap_children_json(j, host)
        end
      end

      private def self.sitemap_node_json(j : JSON::Builder, node : Sitemap::Node) : Nil
        j.object do
          j.field "label", node.label
          j.field "path", node.path
          unless node.methods.empty?
            j.field("methods") { j.array { node.methods.each { |m| j.string(m) } } }
          end
          j.field "grouped", true if node.grouped
          if t = node.tag
            j.field "tag", t
          end
          sitemap_children_json(j, node)
        end
      end

      private def self.sitemap_children_json(j : JSON::Builder, node : Sitemap::Node) : Nil
        return if node.children.empty?
        j.field "children" do
          j.array { node.children.each { |c| sitemap_node_json(j, c) } }
        end
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
