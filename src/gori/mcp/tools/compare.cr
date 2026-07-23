require "json"
require "../../store"
require "../../repeater/message_lines"
require "../../repeater/diff"
require "../serialize"

module Gori
  module MCP
    class Tools
      # Diff two flows' request or response — the MCP counterpart of the TUI's
      # Comparer tab (src/gori/tui/comparer_view.cr). Reuses Repeater::MessageLines
      # (decode/split) and Repeater::Diff (LCS line diff), same engine and MAX_LINES
      # cap, so the comparison matches what a human sees in the Comparer tab.
      private def compare_flows(h) : Result
        id_a = int(h, "flow_id_a")
        return err(id_error(h, "flow_id_a"), "INVALID_ARGUMENT", field: "flow_id_a") unless id_a
        id_b = int(h, "flow_id_b")
        return err(id_error(h, "flow_id_b"), "INVALID_ARGUMENT", field: "flow_id_b") unless id_b
        detail_a = store.get_flow(id_a)
        return not_found("no flow with id #{id_a}") unless detail_a
        detail_b = store.get_flow(id_b)
        return not_found("no flow with id #{id_b}") unless detail_b

        pane_s = str(h, "pane").try(&.strip.downcase)
        if pane_s && !pane_s.in?("request", "response")
          return err("invalid 'pane' (expected request|response)", "INVALID_ARGUMENT", field: "pane")
        end
        pane = pane_s == "request" ? :request : :response
        changes_only = bool_arg(h, "changes_only", false)
        include_sensitive = bool_arg(h, "include_sensitive", false)

        lines_a = compare_lines(detail_a, pane, include_sensitive)
        lines_b = compare_lines(detail_b, pane, include_sensitive)
        truncated = lines_a.size > Repeater::Diff::MAX_LINES || lines_b.size > Repeater::Diff::MAX_LINES
        full_diff = Repeater::Diff.lines(lines_a, lines_b)
        change_count = Repeater::Diff.change_count(full_diff)
        diff = changes_only ? full_diff.reject { |dl| dl.kind == Repeater::DiffKind::Same } : full_diff

        Result.new(JSON.build do |j|
          j.object do
            j.field "flow_id_a", id_a
            j.field "flow_id_b", id_b
            j.field "pane", pane.to_s
            j.field "changed_lines", change_count
            j.field "identical", change_count == 0
            j.field "truncated", truncated
            j.field "diff" do
              j.array do
                diff.each do |dl|
                  j.object do
                    j.field "kind", dl.kind.to_s.downcase
                    j.field "text", dl.text
                  end
                end
              end
            end
          end
        end)
      end

      private def compare_lines(d : Store::FlowDetail, pane : Symbol, include_sensitive : Bool) : Array(String)
        if pane == :request
          Repeater::MessageLines.of(redacted_head(d.request_head, include_sensitive), d.request_body, decode: false)
        else
          Repeater::MessageLines.of(redacted_head(d.response_head, include_sensitive), d.response_body, decode: true)
        end
      end

      # Authorization/Cookie/Set-Cookie/API-key header VALUES are [REDACTED] unless
      # include_sensitive:true — same default as get_flow/intercept_get/
      # get_repeater_context. Applied before diffing so a redacted value can't leak
      # through the `text` field of a diff line.
      private def redacted_head(head : Bytes?, include_sensitive : Bool) : Bytes?
        return head unless head
        Serialize.redact_head(String.new(head).scrub, include_sensitive).to_slice
      end
    end
  end
end
