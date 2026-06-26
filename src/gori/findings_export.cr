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
            io << "\n## [" << f.severity.label << "] " << f.title << "\n\n"
            io << "- **Severity:** " << f.severity.label << "\n"
            io << "- **Status:** " << f.status.label << "\n"
            io << "- **Host:** " << (f.host || "—") << "\n"
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

      private def self.append_evidence(io : String::Builder, label : String, head : Bytes?, body : Bytes?) : Nil
        return if head.nil? || head.empty?
        cap = EVIDENCE_CAP
        io << "\n### " << label << "\n\n```http\n"
        # HEAD: headers are text but can carry stray non-UTF-8 (obs-text) bytes — scrub
        # them so the report stays a valid UTF-8 file; cap it like the body. rstrip the
        # header block's trailing CRLF CRLF so a single blank line (added below) sits
        # between headers and body instead of a stack of empty lines.
        hslice = head.size > cap ? head[0, cap] : head
        io << String.new(hslice).scrub.rstrip
        io << "\n\n[… headers truncated, #{head.size} bytes total …]" if head.size > cap
        if body && !body.empty?
          slice = body[0, {body.size, cap}.min]
          text = String.new(slice)
          if text.valid_encoding?
            io << "\n\n" << text
            io << "\n\n[… body truncated, #{body.size} bytes total …]" if body.size > cap
          else
            io << "\n\n[binary body omitted, #{body.size} bytes]"
          end
        end
        io << "\n```\n"
      end
    end
  end
end
