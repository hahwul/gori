require "json"
require "./store"

module Gori
  module Findings
    # Serialises findings to a Markdown report or JSON. Extracted from the TUI's
    # FindingsController so the in-app export verb and `gori run findings` share one
    # source of truth. Pure: takes the findings + the store (to resolve linked flow
    # evidence) + the project name; returns a String.
    module Export
      # Per-side cap on evidence bytes embedded in the Markdown report.
      EVIDENCE_CAP = 64 * 1024

      def self.markdown(findings : Array(Store::Finding), store : Store, project_name : String) : String
        String.build do |io|
          io << "# Findings — " << project_name << "\n\n"
          io << "_" << findings.size << " findings · exported " << Time.local.to_s("%Y-%m-%d %H:%M") << "_\n"
          findings.each do |f|
            flow = f.flow_id.try { |fid| store.get_flow(fid) }
            io << "\n## [" << f.severity.label << "] " << one_line(f.title) << "\n\n"
            io << "- **Severity:** " << f.severity.label << "\n"
            io << "- **Status:** " << f.status.label << "\n"
            io << "- **Host:** " << (f.host.try { |h| one_line(h) } || "—") << "\n"
            if fid = f.flow_id
              io << "- **Flow:** "
              if flow
                loc = flow.row.target.starts_with?("http") ? flow.row.target : "#{flow.row.host}#{flow.row.target}"
                io << flow.row.method << " " << loc << " → " << (flow.row.status || "-") << " (#" << fid << ")\n"
              else
                io << "#" << fid << " (no longer captured)\n"
              end
            end
            io << "\n" << f.notes << "\n" unless f.notes.strip.empty?
            if flow
              append_evidence(io, "Request", flow.request_head, flow.request_body)
              append_evidence(io, "Response", flow.response_head, flow.response_body)
            end
          end
        end
      end

      def self.json(findings : Array(Store::Finding)) : String
        JSON.build do |j|
          j.array do
            findings.each do |f|
              j.object do
                j.field "id", f.id
                j.field "title", f.title
                j.field "severity", f.severity.label
                j.field "status", f.status.label
                j.field "host", f.host
                j.field "flow_id", f.flow_id
                j.field "created_at", f.created_at
                j.field "updated_at", f.updated_at
                j.field "notes", f.notes
              end
            end
          end
        end
      end

      # Collapse control characters (CR/LF/tab/…) to a single space so a value with
      # embedded newlines can't break the single-line structure it sits in — a
      # Markdown heading here, a one-row line in the text export. Shared with
      # `gori run findings --format text`.
      def self.one_line(s : String) : String
        s.gsub(/[[:cntrl:]]+/, " ").strip
      end

      private def self.append_evidence(io : String::Builder, label : String, head : Bytes?, body : Bytes?) : Nil
        return if head.nil? || head.empty?
        cap = EVIDENCE_CAP
        # Build the embedded request/response text first, THEN pick a fence longer
        # than any backtick run inside it. Bodies are fully attacker-controlled
        # (proxied traffic), so a bare ``` line in a body would otherwise close the
        # ```http fence early and inject live Markdown/HTML into the shared report.
        content = String.build do |c|
          # HEAD: headers are text but can carry stray non-UTF-8 (obs-text) bytes —
          # scrub them so the report stays valid UTF-8; cap it like the body. rstrip
          # the header block's trailing CRLF CRLF so a single blank line (added
          # below) sits between headers and body instead of a stack of empty lines.
          hslice = head.size > cap ? head[0, cap] : head
          c << String.new(hslice).scrub.rstrip
          c << "\n\n[… headers truncated, #{head.size} bytes total …]" if head.size > cap
          if body && !body.empty?
            # Decide text-vs-binary on the WHOLE body, not the truncated slice: cutting at
            # `cap` bytes can split a UTF-8 codepoint, making the slice invalid even for a
            # valid-UTF-8 body — which previously dropped it as "[binary body omitted]".
            if String.new(body).valid_encoding?
              slice = body[0, {body.size, cap}.min]
              c << "\n\n" << String.new(slice).scrub # scrub the partial codepoint at the cut
              c << "\n\n[… body truncated, #{body.size} bytes total …]" if body.size > cap
            else
              c << "\n\n[binary body omitted, #{body.size} bytes]"
            end
          end
        end
        fence = "`" * fence_len(content)
        io << "\n### " << label << "\n\n" << fence << "http\n"
        io << content << "\n" << fence << "\n"
      end

      # A CommonMark fenced block is closed only by a line of >= as many backticks
      # as the opener, so use one more than the longest backtick run in the content
      # (minimum 3) — guaranteeing no embedded line can terminate it.
      private def self.fence_len(content : String) : Int32
        longest = 0
        run = 0
        content.each_char do |ch|
          if ch == '`'
            run += 1
            longest = run if run > longest
          else
            run = 0
          end
        end
        {3, longest + 1}.max
      end
    end
  end
end
