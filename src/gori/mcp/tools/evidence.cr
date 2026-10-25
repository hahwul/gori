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
      # `get_issue` only summarises (provenance and hashes); link/unlink only change Issue
      # membership; `delete_evidence` is the copy's only way out. Bytes come back the way
      # `get_flow` returns them — heads redacted unless `include_sensitive`, bodies decoded
      # and capped — never through the activity feed.

      FREEZE_SOURCES = [Store::LinkRefKind::Flow, Store::LinkRefKind::Repeater].map(&.label)

      @[Tool("freeze_evidence", gated: true, agent_action: true, permission: "write")]
      private def freeze_evidence(h) : Result
        issue_id = required_id(h, "issue_id")
        return not_found("no issue with id #{issue_id}") unless store.get_issue(issue_id)
        kind_s = str(h, "ref_kind").try(&.strip.downcase).presence
        return err("missing required 'ref_kind' (flow|repeater)", "INVALID_ARGUMENT", field: "ref_kind") unless kind_s
        kind = Store::LinkRefKind.parse(kind_s)
        unless kind && Evidence.freezable?(kind)
          return err("invalid ref_kind '#{kind_s}' (flow|repeater — a fuzz or miner session has no single exchange to freeze)",
            "INVALID_ARGUMENT", field: "ref_kind")
        end
        ref_id = required_id(h, "ref_id")
        link = bool_arg(h, "link", true)

        snap = Evidence.snapshot_for(store, kind, ref_id)
        return not_found(snap) if snap.is_a?(String)
        # The one pairing that breaks this tool's own promise, refused by name (#1038). An
        # agent has no tab to look at, so the TUI's "ask and let the operator decide" has no
        # counterpart here — `allow_drift:true` is the deliberate override. CONFIRM_REQUIRED,
        # the code every other gated-by-a-boolean write here answers with (`delete_repeater`,
        # `delete_flows`, a large retest), because nothing in the CALL is wrong: the project
        # is in a state this write would misrepresent, and the field named is the way past it.
        if drift = Evidence.drift_refusal(snap, bool_arg(h, "allow_drift", false), "allow_drift:true")
          return err(drift, "CONFIRM_REQUIRED", field: "allow_drift")
        end

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

      # `issue_id` is OPTIONAL: without it this is the project-wide archive the TUI's
      # Evidence tab shows, newest first — which is the only listing that can name an
      # ORPHAN (a snapshot whose last issue link was removed, or whose issue was deleted).
      # Scoping the only listing to an issue would make those copies unfindable by id alone.
      @[Tool("list_evidence")]
      private def list_evidence(h) : Result
        issue_id = int(h, "issue_id")
        return Result.new(id_error(h, "issue_id"), is_error: true) if issue_id.nil? && present?(h, "issue_id")
        if issue_id
          return not_found("no issue with id #{issue_id}") unless store.get_issue(issue_id)
        end
        metas = issue_id ? store.issue_evidence(issue_id) : store.evidence
        # Under REPLY_ROWS_BUDGET (#1649): a row carries two digests and a URL, so an archive
        # of a hundred copies outgrew it. `offset` pages the rest.
        offset = clamp_nonneg(optional_int_arg(h, "offset"))
        page = offset_slice(metas, offset)
        parts = fit_rows(page) { |rj, m, _| rj.object { Serialize.evidence_meta(rj, m) } }
        Result.new(JSON.build do |j|
          j.object do
            j.field "issue_id", issue_id
            j.field "scope", issue_id ? "issue" : "project"
            j.field("evidence") { raw_rows(j, parts) }
            emit_offset_page(j, offset, parts.size, page.size, metas.size)
            j.field "total", metas.size
            j.field "bytes", metas.sum(&.bytes)
          end
        end)
      end

      @[Tool("get_evidence")]
      private def get_evidence(h) : Result
        id = required_id(h, "id")
        ev = store.get_evidence(id)
        return not_found("no frozen evidence with id #{id}") unless ev
        include_sensitive = bool_arg(h, "include_sensitive", false)
        opts = body_return_opts(h)
        return opts if opts.is_a?(Result)
        cap, omit = opts
        ev, redaction = redact_evidence(ev, include_sensitive)
        Result.new(Serialize.evidence_json(ev, include_sensitive, cap, omit, redaction))
      end

      # The project's ambient body redaction (#1035), over the frozen copy as `get_flow` applies
      # it to the live flow and the TUI's evidence copy (`sanitized_evidence`) to this same row:
      # a field `get_flow` masks must not come back in clear because it was frozen first.
      # `include_sensitive` turns it off, the one flag for both axes as on `get_flow`.
      private def redact_evidence(ev : Store::IssueEvidence,
                                  include_sensitive : Bool) : {Store::IssueEvidence, Serialize::RedactionNote?}
        return {ev, nil} if include_sensitive
        matcher = Redact::Policy.ambient(store) || return {ev, nil}
        clean, count, decoded = Redact::Wire.evidence(ev, matcher)
        {clean, Serialize::RedactionNote.new(matcher.profile.name, count, 0, decoded)}
      end

      @[Tool("delete_evidence", gated: true, agent_action: true, permission: "write")]
      private def delete_evidence(h) : Result
        id = required_id(h, "id")
        meta = store.get_evidence_meta(id)
        return not_found("no frozen evidence with id #{id}") unless meta
        return busy("frozen evidence NOT deleted (store busy or unwritable); it is unchanged") unless store.delete_evidence(id)
        Result.new({"deleted" => true, "id" => id, "issue_ids" => meta.issue_ids}.to_json)
      end

      @[Tool("link_evidence", gated: true, agent_action: true, permission: "write")]
      private def link_evidence(h) : Result
        id = required_id(h, "id")
        issue_id = required_id(h, "issue_id")
        meta = store.get_evidence_meta(id)
        return not_found("no frozen evidence with id #{id}") unless meta
        return not_found("no issue with id #{issue_id}") unless store.get_issue(issue_id)
        # Said, as `gori run evidence link` says it, so a no-op reads apart from a new link.
        already = meta.issue_ids.includes?(issue_id)
        return busy("evidence link NOT written (store busy or either row disappeared)") unless store.link_evidence(id, issue_id)
        Result.new({"linked" => true, "id" => id, "issue_id" => issue_id, "already_linked" => already}.to_json)
      end

      @[Tool("unlink_evidence", gated: true, agent_action: true, permission: "write")]
      private def unlink_evidence(h) : Result
        id = required_id(h, "id")
        issue_id = required_id(h, "issue_id")
        meta = store.get_evidence_meta(id)
        return not_found("no frozen evidence with id #{id}") unless meta
        return not_found("evidence #{id} is not linked to issue #{issue_id}") unless meta.issue_ids.includes?(issue_id)
        return busy("evidence link NOT removed (store busy or link disappeared)") unless store.unlink_evidence(id, issue_id)
        Result.new({"unlinked" => true, "id" => id, "issue_id" => issue_id,
                    "orphaned" => store.get_evidence_meta(id).try(&.orphaned?) || false}.to_json)
      end

      private def list_evidence_tools(j : JSON::Builder) : Nil
        tool j, "list_evidence",
          "List FROZEN evidence (immutable exchange copies) with provenance, linked issues and " \
          "SHA-256s. Without issue_id: the whole archive, newest first, orphans included. A " \
          "deleted History source shows as detached (negative source_id, never a reused " \
          "flow). get_evidence returns the bytes." do |s|
          s.field "issue_id", intprop("one issue's copies only (omit for the whole archive)")
          s.field "offset", intprop("copies to skip (default 0); `has_more` says there are more")
        end

        tool j, "get_evidence",
          "One frozen copy with its bytes: heads (credentials redacted unless " \
          "include_sensitive) and decoded bodies, capped like get_flow. The SHA-256s cover " \
          "stored wire bytes; verifying them needs include_sensitive." do |s|
          s.field "id", intprop("the frozen evidence id (from list_evidence or get_issue)"), required: true
          s.field "include_sensitive", boolprop("emit credential header values verbatim")
          s.field "body_mode", enumprop("default: whole decoded body up to the cap; preview: first 2 KB; none: shape only", ["full", "preview", "none"])
          s.field "max_body_bytes", intprop("cap on each inlined decoded body (default 65536)")
        end

        return unless @allow_actions

        tool j, "freeze_evidence",
          "Freeze a flow's or Repeater tab's CURRENT exchange as immutable evidence on an " \
          "issue, with a SHA-256 per message. Do it the moment a response proves a finding: a " \
          "tab's next send and flow retention replace live copies; a frozen one never changes. " \
          "Refused: a never-sent tab, or one whose request was edited after its response — " \
          "re-send, or set allow_drift. `link` (default true) also files the add_link link." do |s|
          s.field "issue_id", intprop("the issue that owns the copy"), required: true
          s.field "ref_kind", enumprop("what to copy from", FREEZE_SOURCES), required: true
          s.field "ref_id", intprop("the flow or repeater id"), required: true
          s.field "link", boolprop("also attach the live link (default true)")
          s.field "allow_drift", boolprop("freeze a Repeater tab whose request was edited after its stored response")
        end
        tool j, "link_evidence",
          "Link a frozen copy to another issue too; bytes, hashes and provenance are unchanged." do |s|
          s.field "id", intprop("the frozen evidence id"), required: true
          s.field "issue_id", intprop("the issue to link"), required: true
        end

        tool j, "unlink_evidence",
          "Remove one issue link, keeping the frozen copy; removing its last link leaves an " \
          "orphan to relink or delete." do |s|
          s.field "id", intprop("the frozen evidence id"), required: true
          s.field "issue_id", intprop("the issue link to remove"), required: true
        end

        tool j, "delete_evidence",
          "Delete one frozen copy. Its bytes cannot be recovered from the source — prefer " \
          "freezing a newer copy beside it." do |s|
          s.field "id", intprop("the frozen evidence id"), required: true
        end
      end
    end
  end
end
