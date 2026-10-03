require "json"
require "../../store"
require "../../repeater/message_lines"
require "../../repeater/diff"
require "../../repeater/exchange_meta"
require "../serialize"

module Gori
  module MCP
    class Tools
      # Diff two flows' request or response — the MCP counterpart of the TUI's
      # Comparer tab (src/gori/tui/comparer_view.cr). Reuses Repeater::MessageLines
      # (decode/split) and Repeater::Diff (LCS line diff), same engine and MAX_LINES
      # cap, so the comparison matches what a human sees in the Comparer tab.
      @[Tool("compare_flows")]
      private def compare_flows(h) : Result
        id_a = required_id(h, "flow_id_a")
        id_b = required_id(h, "flow_id_b")
        detail_a = store.get_flow(id_a)
        return not_found("no flow with id #{id_a}") unless detail_a
        detail_b = store.get_flow(id_b)
        return not_found("no flow with id #{id_b}") unless detail_b

        pane_s = str(h, "pane").try(&.strip.downcase)
        if pane_s && !MESSAGE_SIDES.includes?(pane_s)
          return err("invalid 'pane' (expected #{MESSAGE_SIDES.join("|")})", "INVALID_ARGUMENT", field: "pane")
        end
        pane = pane_s == "request" ? :request : :response
        changes_only = bool_arg(h, "changes_only", false)
        include_sensitive = bool_arg(h, "include_sensitive", false)
        context = optional_int_arg(h, "context")
        if context && context < 0
          return err("invalid 'context' (expected >= 0)", "INVALID_ARGUMENT", field: "context")
        end
        if context && changes_only
          return err("'changes_only' and 'context' are mutually exclusive", "INVALID_ARGUMENT", field: "context")
        end

        lines_a = compare_lines(detail_a, pane, true)
        lines_b = compare_lines(detail_b, pane, true)
        # The same argument `identical` already makes about a diff cut at MAX_LINES, applied to
        # the cut that happened BEFORE this tool saw the bytes: the proxy stops storing a body
        # at the capture ceiling, so two flows cut at 2 KiB with matching prefixes diff to zero
        # changes. Reporting `identical:true` there is a claim about megabytes gori never held.
        # Named per side, because "which one was cut" is what decides whether the comparison is
        # salvageable by re-sending one of them.
        cut_sides = [] of String
        cut_sides << "a" if detail_a.body_truncated?(pane)
        cut_sides << "b" if detail_b.body_truncated?(pane)
        truncated = Repeater::Diff.truncated?(lines_a, lines_b) || !cut_sides.empty?
        raw_diff = Repeater::Diff.lines(lines_a, lines_b)
        change_count = Repeater::Diff.change_count(raw_diff)
        full_diff, redaction, shown_redacted = redact_diff(raw_diff, detail_a, detail_b, pane, include_sensitive)
        # `context` folds the unchanged runs to counted markers; `changes_only` drops them
        # outright. Folding is the one an agent wants for a long response: it keeps the
        # changes readable in place without claiming the message had nothing else in it.
        diff = if context
                 # Clamp in Int64 before narrowing. The guard above only rejects a NEGATIVE
                 # context, so `{"context": 5000000000}` reached a checked `.to_i` and
                 # OverflowError'd past the INVALID_ARGUMENT arm at `Tools#call`, coming back
                 # INTERNAL for the caller's own argument. A context at or past the diff's
                 # length folds nothing, so the ceiling is exact, not an approximation.
                 Repeater::Diff.fold(full_diff, context.clamp(0_i64, full_diff.size.to_i64).to_i)
               elsif changes_only
                 full_diff.reject { |dl| dl.kind == Repeater::DiffKind::Same }.map { |dl| Repeater::Diff::Folded.new(dl, 0) }
               else
                 full_diff.map { |dl| Repeater::Diff::Folded.new(dl, 0) }
               end
        # Bound the emitted diff by BYTES, not just MAX_LINES (a line count). A decoded
        # response body can be one enormous line (minified JS/JSON, a base64 data URI up
        # to the 32 MiB decode ceiling), so a 1500-line diff could still be tens of MiB in
        # a single JSON-RPC response. Cap each line's text and the total; flag `truncated`.
        capped, byte_truncated = cap_diff_bytes(diff)
        truncated ||= byte_truncated

        Result.new(JSON.build do |j|
          j.object do
            j.field "flow_id_a", id_a
            j.field "flow_id_b", id_b
            j.field "pane", pane.to_s
            j.field "changed_lines", change_count
            # `identical` is a stronger claim than `changed_lines: 0` and has to earn it:
            # over a CUT diff the honest answer is "unknown", not "the same". `truncated`
            # sits beside it either way, but an agent reading one field should not be told
            # two responses match when only their first MAX_LINES lines were compared.
            j.field "identical", change_count == 0 && !truncated
            j.field "truncated", truncated
            Serialize.emit_redaction_note(j, redaction)
            if shown_redacted
              j.field "diff_of_redacted_copies", true
              j.field "diff_of_redacted_copies_note",
                "the redaction profile rewrote a body, so `diff` compares the two redacted copies and a change " \
                "inside a redacted value may not show as a row; `changed_lines` and `identical` are over the " \
                "captured bytes. Pass include_sensitive:true for the diff of the captured messages"
            end
            unless cut_sides.empty?
              j.field "source_truncated" { j.array { cut_sides.each { |side| j.string side } } }
              j.field "source_truncated_note",
                "the capture cap cut the #{pane} body on #{cut_sides.size == 2 ? "both flows" : "flow #{cut_sides.first}"} " \
                "before this diff saw it, so only the stored prefix was compared and `identical` cannot be true here — " \
                "re-send with send_request to compare whole bodies"
            end
            j.field "meta" do
              j.object do
                meta_a = Repeater::ExchangeMeta.of(detail_a.row)
                meta_b = Repeater::ExchangeMeta.of(detail_b.row)
                {"a" => meta_a, "b" => meta_b}.each do |name, m|
                  j.field name do
                    j.object do
                      j.field "status", m.status
                      j.field "size", m.size
                      j.field "duration_us", m.duration_us
                    end
                  end
                end
                j.field "delta", Repeater::ExchangeMeta.delta(meta_a, meta_b)
              end
            end
            j.field "diff" do
              j.array do
                capped.each do |(kind, text, hidden)|
                  j.object do
                    j.field "kind", kind
                    if kind == "fold"
                      # A folded run is a ROW in the diff, not a gap in it: an agent has to be
                      # able to tell "3 identical lines here" from "nothing here".
                      j.field "hidden", hidden
                    else
                      j.field "text", text
                    end
                  end
                end
              end
            end
          end
        end)
      end

      # Total byte budget for a compare_flows diff's emitted `text` (across all lines),
      # and the per-line ceiling. Generous enough for real request/response diffs while
      # keeping one call off the multi-MB JSON-RPC cliff every other read tool avoids.
      COMPARE_MAX_DIFF_BYTES = 256 * 1024
      COMPARE_MAX_LINE_BYTES = Serialize::MAX_TEXT # 64 KiB — a single huge line still shows a prefix

      # Trim the diff to the byte budget: cap each line's text (byte-safe, then scrub so a
      # cut through a multi-byte UTF-8 sequence can't emit invalid UTF-8 onto the stdio
      # stream), stop once the total budget is spent. Returns the kept {kind, text} pairs
      # and whether anything was trimmed.
      private def cap_diff_bytes(diff : Array(Repeater::Diff::Folded)) : {Array({String, String, Int32}), Bool}
        budget = COMPARE_MAX_DIFF_BYTES
        kept = [] of {String, String, Int32}
        trimmed = false
        diff.each do |f|
          if budget <= 0
            trimmed = true
            break
          end
          unless dl = f.line
            # A fold marker costs no text budget — it carries a count, not bytes.
            kept << {"fold", "", f.hidden}
            next
          end
          text = dl.text
          if text.bytesize > COMPARE_MAX_LINE_BYTES
            text = text.byte_slice(0, COMPARE_MAX_LINE_BYTES).scrub
            trimmed = true
          end
          if text.bytesize > budget
            text = text.byte_slice(0, budget).scrub
            trimmed = true
          end
          budget -= text.bytesize
          kept << {dl.kind.to_s.downcase, text, 0}
        end
        {kept, trimmed}
      end

      private def compare_lines(d : Store::FlowDetail, pane : Symbol, include_sensitive : Bool) : Array(String)
        if pane == :request
          Repeater::MessageLines.of(redacted_head(d.request_head, include_sensitive), d.request_body, decode: false)
        else
          Repeater::MessageLines.of(redacted_head(d.response_head, include_sensitive), d.response_body, decode: true, error: d.error)
        end
      end

      # The diff is taken over the CAPTURED lines and only its `text` is redacted. Redacting
      # first and diffing second decided the verdict on the redacted copy, so the same request
      # sent as Alice and as Bob — the comparison authorization testing is — came back
      # `identical:true` because both tokens read `[REDACTED]`. Redaction decides what a line
      # SHOWS, never whether it changed: a changed credential is a del/add pair whose text is
      # `Authorization: [REDACTED]` on both sides.
      #
      # The shown text is redacted the way `get_flow` redacts the same flows: header values, and
      # the body through the project's ambient redaction profile (#1035), which this tool skipped.
      #
      # Header redaction keeps every line where it was, so when it is all that applied the rows
      # are paired with their redacted twins by walking `Diff.lines`' output with two cursors
      # (Same advances both, Del `a`, Add `b`). A profile that rewrote a body also reframes its
      # head (`Redact::Wire` moves Content-Length, drops a coding), so its lines no longer sit
      # where the captured ones did: then the rows shown are a diff of the two redacted copies,
      # and the third element says so — `changed_lines`/`identical` still describe the bytes.
      private def redact_diff(diff : Array(Repeater::DiffLine), detail_a : Store::FlowDetail,
                              detail_b : Store::FlowDetail, pane : Symbol,
                              include_sensitive : Bool) : {Array(Repeater::DiffLine), Serialize::RedactionNote?, Bool}
        return {diff, nil, false} if include_sensitive
        matcher = Redact::Policy.ambient(store)
        shown_a, hits_a, decoded_a = shown_lines(detail_a, pane, matcher)
        shown_b, hits_b, decoded_b = shown_lines(detail_b, pane, matcher)
        note = matcher.try { |m| Serialize::RedactionNote.new(m.profile.name, hits_a + hits_b, 0, decoded_a || decoded_b) }
        if hits_a + hits_b > 0 || shown_a.size != diff.count { |dl| !dl.kind.add? } ||
           shown_b.size != diff.count { |dl| !dl.kind.del? }
          return {Repeater::Diff.lines(shown_a, shown_b), note, true}
        end
        i = 0
        k = 0
        shown = diff.map do |dl|
          text = case dl.kind
                 when .add?
                   shown_b[k].tap { k += 1 }
                 when .del?
                   shown_a[i].tap { i += 1 }
                 else
                   shown_a[i].tap { i += 1; k += 1 }
                 end
          Repeater::DiffLine.new(dl.kind, text)
        end
        {shown, note, false}
      end

      # One side's lines as shown: header values redacted, and the pane's body through the
      # profile when it has one — only the pane being diffed is decoded and sanitized. Returns
      # the lines (cut where `Diff.lines` cuts), the profile's hit count and whether it decoded.
      private def shown_lines(d : Store::FlowDetail, pane : Symbol,
                              matcher : Redact::Matcher?) : {Array(String), Int32, Bool}
        head, body = pane == :request ? {d.request_head, d.request_body} : {d.response_head, d.response_body}
        hits = 0
        decoded = false
        if matcher && body && !body.empty?
          clean = Redact::Wire.message(head, body, matcher)
          if clean.count > 0
            hits = clean.count
            decoded = clean.decoded?
            head = clean.head unless head.nil?
            body = clean.body
          end
        end
        lines = if pane == :request
                  Repeater::MessageLines.of(redacted_head(head, false), body, decode: false)
                else
                  Repeater::MessageLines.of(redacted_head(head, false), body, decode: true, error: d.error)
                end
        {lines.first(Repeater::Diff::MAX_LINES), hits, decoded}
      end

      # Authorization/Cookie/Set-Cookie/API-key header VALUES are [REDACTED] unless
      # include_sensitive:true — same default as get_flow/intercept_get/
      # get_repeater_context. `redact_diff` applies it to the diff's text only.
      private def redacted_head(head : Bytes?, include_sensitive : Bool) : Bytes?
        return head unless head
        Serialize.redact_head(String.new(head).scrub, include_sensitive).to_slice
      end

      # The tools/list schemas for the flow comparison tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_compare_tools(j : JSON::Builder) : Nil
        tool j, "compare_flows",
          "Line-diff two flows' request or response — the MCP equivalent of the TUI's Comparer " \
          "tab. Response bodies are decoded (de-chunked/decompressed) before diffing; request " \
          "bodies are compared byte-faithful. Returns {changed_lines, identical, truncated, " \
          "source_truncated, " \
          "meta:{a,b:{status,size,duration_us}, delta}, " \
          "diff:[{kind: same|add|del, text} | {kind: fold, hidden}]} (add = only in flow B, " \
          "del = only in flow A; fold = a run of `hidden` identical lines collapsed by `context`). " \
          "`meta.delta` answers the usual question — a status flip, a size or timing shift — " \
          "before any diff line is read. `identical` is only ever true over a COMPLETE " \
          "comparison: a diff cut at the line/byte cap, or a body the capture cap already cut " \
          "(`source_truncated` names which side), sets `truncated` and leaves `identical` " \
          "false, because matching prefixes are not matching bodies. " \
          "Authorization/Cookie/Set-Cookie/API-key header values are [REDACTED] in the diff " \
          "text unless include_sensitive=true; the diff itself is taken over the captured values, so a " \
          "changed credential is still a del/add pair. Pure read: no network, nothing written." do |s|
          s.field "flow_id_a", intprop("first flow id (the 'original' side)"), required: true
          s.field "flow_id_b", intprop("second flow id (the 'new' side)"), required: true
          s.field "pane", enumprop("which half of the two flows to diff (default response)", MESSAGE_SIDES)
          s.field "changes_only", boolprop("omit unchanged (same) lines from the diff (default false)")
          s.field "context", intprop("collapse unchanged runs to {kind:fold,hidden} markers, keeping N lines around each change — the readable form for a long response (mutually exclusive with changes_only)")
          s.field "include_sensitive", boolprop("return Authorization/Cookie/Set-Cookie/API-key header values instead of [REDACTED] (default false)")
        end
      end
    end
  end
end
