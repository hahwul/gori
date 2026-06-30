require "json"
require "../store"
require "../fuzz"
require "../miner"
require "../prism/group"

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
          j.field "state", row.state.to_s
          j.field "size", row.size
          j.field "response_size", row.response_size
          j.field "duration_us", row.duration_us
          j.field "content_type", row.content_type
        end
      end

      # "#42  GET   https  example.com:443/users  200  1.2kB  3ms  [Complete]"
      # Columns are padded for scannability; status/state make capture progress legible.
      def self.flow_row_text(row : Store::FlowRow) : String
        status = row.status.try(&.to_s) || "—"
        # HTTP proxied requests store an absolute-form target ("http://host/path")
        # that already carries the host; only origin-form targets need host prefixed.
        loc = row.target.starts_with?("http") ? row.target : "#{row.host}#{row.target}"
        dur = row.duration_us.try { |us| " #{human_us(us)}" } || ""
        String.build do |io|
          io << '#' << row.id.to_s.ljust(6)
          io << row.method.ljust(7)
          io << row.scheme.ljust(6)
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
          j.field "remediation", Prism.remediation(g.code)
        end
      end

      # "[high]      secret_in_url             api.test   ×3   token"
      # plus an indented representative affected URL ("(+N more)" when capped).
      def self.prism_group_text(g : Prism::Group) : String
        String.build do |io|
          io << "[#{g.severity.label}]".ljust(11)
          io << g.code.ljust(28)
          io << "  " << g.host
          io << "  ×" << g.hit_count
          if ev = g.evidence
            io << "  " << ev
          end
          if first = g.affected.first?
            io << "\n    " << first
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
