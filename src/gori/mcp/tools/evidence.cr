require "json"
require "../../store"
require "../../evidence"

module Gori
  module MCP
    class Tools
      # Frozen issue evidence (#1038) — the immutable copy of one exchange that survives a
      # Repeater re-send and History retention. An agent that confirms a finding and then
      # retests the fix is exactly the workflow the copy exists for: freeze the response that
      # proved it, send again, freeze that too, and the issue holds both.
      #
      # `freeze_evidence` is the write; `list_evidence` / `get_evidence` read what
      # `get_issue` only summarises (provenance and hashes); `delete_evidence` is the copy's
      # only way out. Bytes come back the way `get_flow` returns them — heads redacted unless
      # `include_sensitive`, bodies decoded and capped — never through the activity feed.

      FREEZE_SOURCES = [Store::LinkRefKind::Flow, Store::LinkRefKind::Repeater].map(&.label)

      @[Tool("freeze_evidence", gated: true, agent_action: true)]
      private def freeze_evidence(h) : Result
        issue_id = int(h, "issue_id")
        return Result.new(id_error(h, "issue_id"), is_error: true) unless issue_id
        return not_found("no issue with id #{issue_id}") unless store.get_issue(issue_id)
        kind_s = str(h, "ref_kind").try(&.strip.downcase).presence
        return err("missing required 'ref_kind' (flow|repeater)", "INVALID_ARGUMENT", field: "ref_kind") unless kind_s
        kind = Store::LinkRefKind.parse(kind_s)
        unless kind && Evidence.freezable?(kind)
          return err("invalid ref_kind '#{kind_s}' (flow|repeater — a fuzz or miner session has no single exchange to freeze)",
            "INVALID_ARGUMENT", field: "ref_kind")
        end
        ref_id = int(h, "ref_id")
        return Result.new(id_error(h, "ref_id"), is_error: true) unless ref_id
        link = bool_arg(h, "link", true)

        snap = Evidence.snapshot_for(store, kind, ref_id)
        return not_found(snap) if snap.is_a?(String)

        id, status = store.freeze_evidence(issue_id, snap, link: link)
        case status
        in .issue_gone? then return not_found("issue #{issue_id} was deleted before the copy was written")
        in .quota?
          return err("evidence quota reached (#{store.evidence_bytes} of #{Evidence::QUOTA_BYTES} bytes used) — delete a frozen copy first",
            "QUOTA_EXCEEDED")
        in .busy? then return busy("nothing frozen (store busy or unwritable)")
        in .ok?   then nil
        end
        meta = store.get_evidence_meta(id)
        Result.new(JSON.build do |j|
          j.object do
            j.field "frozen", true
            j.field "linked", link
            if meta
              j.field("evidence") { j.object { Serialize.evidence_meta(j, meta) } }
            else
              j.field "id", id
            end
          end
        end)
      end

      @[Tool("list_evidence")]
      private def list_evidence(h) : Result
        issue_id = int(h, "issue_id")
        return Result.new(id_error(h, "issue_id"), is_error: true) unless issue_id
        return not_found("no issue with id #{issue_id}") unless store.get_issue(issue_id)
        metas = store.issue_evidence(issue_id)
        Result.new(JSON.build do |j|
          j.object do
            j.field "issue_id", issue_id
            j.field("evidence") { j.array { metas.each { |m| j.object { Serialize.evidence_meta(j, m) } } } }
            j.field "total", metas.size
            j.field "bytes", metas.sum(&.bytes)
          end
        end)
      end

      @[Tool("get_evidence")]
      private def get_evidence(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        ev = store.get_evidence(id)
        return not_found("no frozen evidence with id #{id}") unless ev
        include_sensitive = bool_arg(h, "include_sensitive", false)
        opts = body_return_opts(h)
        return opts if opts.is_a?(Result)
        cap, omit = opts
        Result.new(Serialize.evidence_json(ev, include_sensitive, cap, omit))
      end

      @[Tool("delete_evidence", gated: true, agent_action: true)]
      private def delete_evidence(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        meta = store.get_evidence_meta(id)
        return not_found("no frozen evidence with id #{id}") unless meta
        return busy("frozen evidence NOT deleted (store busy or unwritable); it is unchanged") unless store.delete_evidence(id)
        Result.new({"deleted" => true, "id" => id, "issue_id" => meta.issue_id}.to_json)
      end

      private def list_evidence_tools(j : JSON::Builder) : Nil
        tool j, "list_evidence",
          "List an issue's FROZEN evidence: immutable copies of a flow's or a Repeater tab's " \
          "exchange, taken at the moment they proved the finding, with provenance (source, " \
          "time, status, size) and SHA-256 of the stored request and response. A copy survives " \
          "the Repeater's next send and History retention; use get_evidence for its bytes." do |s|
          s.field "issue_id", intprop("the issue id"), required: true
        end

        tool j, "get_evidence",
          "One frozen copy with its bytes — request/response heads (Authorization/Cookie " \
          "redacted unless include_sensitive) and bodies (decoded, capped like get_flow). " \
          "The SHA-256s cover the stored wire bytes, so verifying them needs include_sensitive." do |s|
          s.field "id", intprop("the frozen evidence id (from list_evidence or get_issue)"), required: true
          s.field "include_sensitive", boolprop("emit credential header values verbatim (default false)")
          s.field "body_mode", enumprop("how much body to inline: the default is the whole decoded body up to the cap, preview the first 2 KB, none the shape only", ["full", "preview", "none"])
          s.field "max_body_bytes", intprop("cap on each inlined decoded body (default 65536)")
        end

        return unless @allow_actions

        tool j, "freeze_evidence",
          "Freeze a flow's or a Repeater tab's CURRENT exchange as immutable evidence on an " \
          "issue — request, response, status, timing, protocol, error and truncation state, " \
          "with a SHA-256 of each. Do this the moment a response proves a finding: the tab's " \
          "next send replaces its response and retention prunes flows, but a frozen copy is " \
          "never changed or pruned. Freeze again after a retest to keep both. A never-sent " \
          "Repeater tab is refused (there is no exchange). `link:true` (default) also files " \
          "the live link add_link would, in the same transaction." do |s|
          s.field "issue_id", intprop("the issue that owns the copy"), required: true
          s.field "ref_kind", enumprop("what to copy from", FREEZE_SOURCES), required: true
          s.field "ref_id", intprop("the flow or repeater id"), required: true
          s.field "link", boolprop("also attach the live link (default true)")
        end

        tool j, "delete_evidence",
          "Delete one frozen copy. The bytes cannot be recovered from the source — that is " \
          "why they were frozen — so prefer freezing a newer copy beside it to replacing it." do |s|
          s.field "id", intprop("the frozen evidence id"), required: true
        end
      end
    end
  end
end
