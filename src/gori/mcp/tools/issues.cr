require "json"
require "../../store"
require "../serialize"
require "../../env"
require "../../utf8"

module Gori
  module MCP
    class Tools
      ISSUES_LIMIT  = PageLimit.new(100, 500)
      ISSUE_FORMATS = %w[json markdown sarif]
      # 500 issues × two (2 KiB + 1) reads stays below the 2 MiB body-read budget.
      REPORT_EVIDENCE_CAP = 2 * 1024

      # Characters of an issue's `notes` a list_issues row carries; get_issue has the rest.
      ISSUE_NOTES_PREVIEW = 200

      # `links` / `evidence` entries a list_issues row carries, and get_issue's own cap on
      # them; list_links / list_evidence page the rest.
      ISSUE_ITEMS_PREVIEW =  5
      ISSUE_ITEMS_MAX     = 25

      @[Tool("list_issues")]
      private def list_issues(h) : Result
        format = str(h, "format") || "json"
        unless ISSUE_FORMATS.includes?(format)
          return err("format must be #{ISSUE_FORMATS.join("|")}", "INVALID_ARGUMENT", field: "format")
        end
        if format == "json" && present?(h, "include_sensitive")
          return err("'include_sensitive' only applies to report formats", "INVALID_ARGUMENT", field: "include_sensitive")
        end
        pg = page_args(h, ISSUES_LIMIT)
        all = store.issues
        # The TUI `/` bar's own filter, refused where the bar only notes it: an agent reading
        # an empty page cannot tell a typo'd `stauts:open` from "no open issues".
        if q = str(h, "query").presence
          if why = Issues::Filter.refusal(q, lenient: bool_arg(h, "lenient", false))
            return err(why, "INVALID_ARGUMENT", field: "query")
          end
          all = Issues::Filter.parse(q).apply(all)
        end
        page = all[pg.offset, pg.limit]? || [] of Store::Issue
        return issues_report_export(h, page, all.size, pg, format) unless format == "json"
        parts = fit_rows(page) { |rj, f, _| Serialize.issue(rj, f, store, notes_preview: ISSUE_NOTES_PREVIEW, items_cap: ISSUE_ITEMS_PREVIEW) }
        cut = parts.size < page.size
        page = page.first(parts.size)
        Result.new(JSON.build do |j|
          j.object do
            j.field("issues") { raw_rows(j, parts) }
            emit_page(j, pg, page.size, all.size, cut: cut)
          end
        end)
      end

      private def issues_report_export(h, page : Array(Store::Issue), total : Int32, pg : Page,
                                       format : String) : Result
        include_sensitive = bool_arg(h, "include_sensitive", false)
        matcher = include_sensitive ? nil : Redact::Policy.ambient(store)
        name = @project_name || "project"
        # Cache projections across the bounded binary search; never re-read/inflate a flow.
        flows = {} of Int64 => Store::FlowDetail?
        loader = ->(id : Int64) do
          flows.fetch(id) do
            flows[id] = report_flow(id, REPORT_EVIDENCE_CAP, include_sensitive, matcher)
          end
        end
        render = ->(count : Int32) do
          selected = page.first(count)
          if format == "sarif"
            Issues::Export.sarif(selected, store, name, include_sensitive, flow_loader: loader)
          else
            Issues::Export.markdown(selected, store, name, flow_loader: loader, include_sensitive: include_sensitive)
          end
        end
        returned = page.size
        document = render.call(returned)
        if document.bytesize > Serialize::MAX_TEXT
          return err("report header exceeds the 64 KiB report cap", "QUOTA_EXCEEDED") if page.empty?
          low, high = 0, page.size
          while low < high
            candidate = (low + high + 1) // 2
            trial = render.call(candidate)
            if trial.bytesize <= Serialize::MAX_TEXT
              low = candidate
              document = trial
            else
              high = candidate - 1
            end
          end
          # Unbounded notes, heads or related metadata can exceed the cap even without bodies.
          return err("issue #{page.first.id} alone exceeds the 64 KiB report cap; read it with get_issue", "QUOTA_EXCEEDED") if low == 0
          returned = low
        end
        included = page.first(returned)
        evidence_cut = included.any? do |issue|
          flow = issue.flow_id.try { |id| flows[id]? }
          flow.try { |f| f.request_body_truncated? || f.response_body_truncated? }
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "format", format
            j.field "document", document
            j.field "evidence_truncated", evidence_cut
            emit_page(j, pg, returned, total, cut: returned < page.size)
            j.field "sensitive_headers_redacted", true unless include_sensitive
            j.field "redaction_profile", matcher.profile.name if matcher
          end
        end)
      end

      private def report_flow(id : Int64, cap : Int32, include_sensitive : Bool, matcher : Redact::Matcher?)
        flow = store.get_flow(id, body_max: cap + 1)
        return nil unless flow
        req_head, req, req_cut = report_message(flow.request_head, flow.request_body, cap, flow.request_body_truncated?, matcher)
        res_head, res, res_cut = report_message(flow.response_head, flow.response_body, cap, flow.response_body_truncated?, matcher)
        # Project heads BEFORE parsing: a malformed credential line must not reappear as
        # a folded public value or a response reason phrase.
        Store::FlowDetail.new(flow.row, flow.http_version,
          Serialize.redact_head(String.new(req_head || Bytes.empty), include_sensitive).to_slice, req,
          Serialize.redact_head_bytes(res_head, include_sensitive), res,
          flow.h2_conn_id, flow.h2_stream_id, req_cut, res_cut, flow.error, flow.sni)
      end

      private def report_message(head : Bytes?, body : Bytes?, cap : Int32, capture_cut : Bool,
                                 matcher : Redact::Matcher?) : {Bytes?, Bytes?, Bool}
        return {head, body, capture_cut} unless body
        decoded, note, complete = Proxy::Codec::ContentDecode.decode_full(head, body, cap + 1)
        entity = decoded || body
        cut = capture_cut || entity.size > cap || !complete
        # A partial JSON document cannot honor JSON Pointers. Withhold it under a profile,
        # and never feed compressed prefixes back to an exporter for unbounded inflation.
        return {head, nil, true} if (cut && matcher) || Proxy::Codec::ContentDecode.decode_failed?(note)
        entity = Utf8.trim_incomplete_end(entity[0, cap]) if entity.size > cap
        head, entity = redact_report_message(head, entity, matcher, !decoded.nil?)
        return {head, nil, true} if entity.size > cap
        {head, entity, cut}
      end

      private def redact_report_message(head : Bytes?, entity : Bytes, matcher : Redact::Matcher?, decoded : Bool)
        entity = matcher.body(entity, MediaType.of(head)).bytes if matcher
        if decoded || matcher
          head = Redact::Wire.reframe(head || Bytes.empty, entity.size, drop_transfer: decoded)
        end
        {head, entity}
      end

      @[Tool("get_issue")]
      private def get_issue(h) : Result
        id = required_id(h, "id")
        f = store.get_issue(id)
        return not_found("no issue with id #{id}") unless f
        Result.new(JSON.build { |j| Serialize.issue(j, f, store, retest: true, items_cap: ISSUE_ITEMS_MAX) })
      end

      @[Tool("create_issue", gated: true, agent_action: true, permission: "write", open_world: false, destructive: false)]
      private def create_issue(h) : Result
        title = str(h, "title")
        return Result.new("missing required 'title'", is_error: true) if title.nil? || title.strip.empty?
        # Mask secrets in issue title
        masked_title = Env.mask_secrets(title)

        # An unrecognised severity is rejected, not silently coerced to Info —
        # matching update_issue (a typo'd 'severity' shouldn't quietly become
        # an info issue). An absent/blank severity still defaults to Info.
        sev_s = str(h, "severity")
        if err = bad_severity(sev_s)
          return err
        end
        # `clear` has nothing to clear on a create, so only the value half is read here.
        cvss, _ = cvss_arg(h)
        if err = bad_cvss(cvss)
          return err
        end
        severity = severity_from(sev_s) || cvss.try { |c| Gori::Cvss.severity_for(c) } || Store::Severity::Info
        # A present-but-invalid flow_id (1.9 / "oops") would otherwise be
        # silently nulled, creating an UNLINKED issue while reporting success —
        # reject it, consistent with how get_flow rejects a non-integer id.
        flow_id = int(h, "flow_id")
        return Result.new("invalid 'flow_id' (expected an integer)", is_error: true) if flow_id.nil? && present?(h, "flow_id")
        # ...and a well-formed id that names NO flow is just as broken: it produces an issue
        # whose evidence pointer resolves to nothing, reported as a success. repeater_id has
        # always been checked; flow_id was not. flow_row is the row-only read (get_flow would
        # materialize both BLOBs just to answer "does this exist?").
        if flow_id && !store.flow_row(flow_id)
          return not_found("no flow with id #{flow_id}")
        end
        repeater_id = int(h, "repeater_id")
        return Result.new(id_error(h, "repeater_id"), is_error: true) if repeater_id.nil? && present?(h, "repeater_id")
        if repeater_id && !store.get_repeater(repeater_id)
          return not_found("no repeater with id #{repeater_id}")
        end

        # No host given: the filing flow's, as the TUI form pre-fills it, so `host:` filters and
        # the report do not miss an issue filed with only a `flow_id`.
        host = (str(h, "host").try(&.strip).presence || flow_id.try { |fid| store.flow_row(fid).try(&.host) }).try { |hst| Env.mask_secrets(hst) }
        # The body, written by the SAME insert as the issue — the atomicity `gori run issues
        # create --notes/--notes-file` already advertises. Without it an agent filing findings
        # in bulk had to follow every create with an `update_issue(notes:)`: two writes, and an
        # issue that exists bodiless in between. `|| ""` is the column's own default, not a
        # fallback that loses anything — no `notes` argument still creates a bodiless issue.
        # Masked like the title and host beside it, and like update_issue's own `notes`.
        notes = str(h, "notes").try { |n| Env.mask_secrets(n) } || ""
        id = store.insert_issue(masked_title, severity, host, flow_id, cvss: cvss, notes: notes)
        # insert_issue returns 0 (never raises) when the write batch fails — e.g.
        # the cross-process SQLite lock couldn't be acquired (a TUI capturing into
        # the same project) or the disk is full. Don't report a phantom success.
        return busy("failed to persist issue (store busy or unwritable)") if id == 0
        if repeater_id && !link_issue_repeater(id, repeater_id)
          # The issue IS stored, so the answer names it: a retry of the create would file a
          # duplicate.
          return busy("issue #{id} created but its repeater link NOT written (store busy or unwritable); " \
                      "retry with update_issue(id: #{id}, repeater_id: #{repeater_id})")
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "repeater_id", repeater_id if repeater_id
          end
        end)
      end

      # Link the issue to the repeater; false only when no such link exists afterwards
      # (`Store#ensure_link`, which `gori run issues --repeater` uses too). Every MCP
      # issue→repeater link write goes through here (create_repeater, send_request,
      # send_websocket too), so none reports a link that did not commit.
      private def link_issue_repeater(issue_id : Int64, repeater_id : Int64) : Bool
        store.ensure_link(Store::LinkOwnerKind::Issue, issue_id, Store::LinkRefKind::Repeater, repeater_id)
      end

      @[Tool("update_issue", gated: true, agent_action: true, permission: "write", open_world: false)]
      private def update_issue(h) : Result
        id = required_id(h, "id")
        return not_found("no issue with id #{id}") unless store.get_issue(id)
        # A blank severity/status means "leave unchanged"; only a present,
        # non-blank, unrecognised value is an error.
        sev_s = str(h, "severity")
        if err = bad_severity(sev_s)
          return err
        end
        stat_s = str(h, "status")
        if err = bad_status(stat_s)
          return err
        end

        cvss, clear_cvss = cvss_arg(h)
        if err = bad_cvss(cvss)
          return err
        end

        title = str(h, "title").try { |t| Env.mask_secrets(t) }
        return Result.new("title must not be empty", is_error: true) if title && title.strip.empty?
        notes = str(h, "notes").try { |n| Env.mask_secrets(n) }
        severity = severity_from(sev_s) || (cvss ? Gori::Cvss.severity_for(cvss) : nil)
        status = status_from(stat_s)
        repeater_id = int(h, "repeater_id")
        return Result.new(id_error(h, "repeater_id"), is_error: true) if repeater_id.nil? && present?(h, "repeater_id")
        if repeater_id && !store.get_repeater(repeater_id)
          return not_found("no repeater with id #{repeater_id}")
        end
        # `host` / `flow_id` (#1686), read like `cvss`: null (or an empty host) clears it. A new
        # seed flow is checked as create_issue checks it.
        host, clear_host = cvss_arg(h, "host")
        host = host.try { |hst| Env.mask_secrets(hst) }
        flow_id = int(h, "flow_id")
        clear_flow = h["flow_id"]?.try(&.raw.nil?) || false
        return Result.new("invalid 'flow_id' (expected an integer)", is_error: true) if flow_id.nil? && present?(h, "flow_id")
        if flow_id && !store.flow_row(flow_id)
          return not_found("no flow with id #{flow_id}")
        end

        # Don't claim updated:true on a no-op. With no resolvable field the store
        # write is a silent no-op, so returning success would mislead the caller
        # (e.g. it'd think a typo'd field name took effect).
        fields = !(title.nil? && severity.nil? && notes.nil? && status.nil? && cvss.nil? && !clear_cvss &&
                   host.nil? && !clear_host && flow_id.nil? && !clear_flow)
        if !fields && repeater_id.nil?
          return nothing_to_change_refusal("update_issue") || err("nothing to change — this call sets no field", "INVALID_ARGUMENT")
        end

        if fields
          return busy("issue NOT updated (store busy or unwritable); it is unchanged") unless store.update_issue(id, title: title, severity: severity, notes: notes, status: status, cvss: cvss, clear_cvss: clear_cvss,
                                                                                                host: host, clear_host: clear_host, flow_id: flow_id, clear_flow: clear_flow)
        end
        if repeater_id && !link_issue_repeater(id, repeater_id)
          return busy("repeater link NOT written (store busy or unwritable); try again")
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "updated", true
            j.field "repeater_id", repeater_id if repeater_id
          end
        end)
      end

      # Remove an issue outright (the TUI Issues tab's delete). Distinct from status
      # "resolved"/"false-positive", which keep it in the report — this drops it, along with
      # its entity links (Store#delete_issue clears those in the same transaction).
      @[Tool("delete_issue", gated: true, agent_action: true, permission: "write", open_world: false)]
      private def delete_issue(h) : Result
        id = required_id(h, "id")
        return not_found("no issue with id #{id}") unless store.get_issue(id)
        return busy("issue NOT deleted (store busy or unwritable); it is unchanged") unless store.delete_issue(id)
        Result.new({id: id, deleted: true}.to_json)
      end

      # The tools/list schemas for the issue tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_issues_tools(j : JSON::Builder) : Nil
        tool j, "list_issues",
          "List triage issues, newest/most-severe first. Returns {issues, returned, offset, " \
          "total}, not a bare array. Each issue's `links` lists what backs it, the flow it was " \
          "filed from first (`flow_id`). `notes` is cut to #{ISSUE_NOTES_PREVIEW} characters " \
          "(`notes_truncated`; get_issue has it whole), `links`/`evidence` to #{ISSUE_ITEMS_PREVIEW} " \
          "(`*_total`, `*_truncated`). Probe scanner findings are probe_issues." do |s|
          s.field "query", strprop("filter, as the TUI's / bar: status:open sev:>=high host:api " \
                                   "cvss:>=7 -status:fp; a bare word searches title and host")
          s.field "lenient", boolprop("free-text an unknown `field:` instead of refusing")
          s.field "limit", limitprop("max rows", ISSUES_LIMIT)
          s.field "offset", intprop("start row (default 0)")
          s.field "format", enumprop("default json; reports fit whole issues in 64 KiB; follow next_offset; evidence_truncated marks body cuts", ISSUE_FORMATS)
          s.field "include_sensitive", boolprop("report formats: unredact credential headers and bodies")
        end

        tool j, "get_issue",
          "One issue: `links` (what backs it, the filing flow first = `flow_id`) and " \
          "`evidence` (frozen copies), #{ISSUE_ITEMS_MAX} each; past that `*_truncated` and " \
          "`*_total`, and list_links / list_evidence page them." do |s|
          s.field "id", intprop("issue id"), required: true
        end

        return unless @allow_actions

        # The description says the body can ride the create, because that is the surface an
        # agent reads when CHOOSING a tool — #1076 was filed over a create+update_issue habit
        # formed when nothing here said otherwise, and a per-property description (below) is
        # only read once this tool has already been picked.
        tool j, "create_issue", "Record a new issue in the project, with its notes body, in one transaction." do |s|
          s.field "title", strprop("issue title"), required: true
          s.field "severity", enumprop("default: derived from cvss, else info", SEVERITIES)
          s.field "cvss", strprop("CVSS vector or score (e.g. 9.8)")
          s.field "notes", strprop("the issue's free-form body")
          s.field "host", strprop("host the issue concerns (default: the flow's)")
          s.field "flow_id", intprop("flow it is filed from; becomes its first linked flow")
          s.field "repeater_id", intprop("repeater id to link")
        end

        tool j, "update_issue", "Update an existing issue's fields." do |s|
          s.field "id", intprop("issue id"), required: true
          s.field "title", strprop("new title")
          s.field "severity", enumprop("new severity", SEVERITIES)
          s.field "cvss", strprop("CVSS vector or score (empty clears)")
          s.field "notes", strprop("free-form body (replaces existing; list_issues shows a preview, read it whole from get_issue)")
          s.field "status", enumprop("new triage state", ISSUE_STATUSES)
          s.field "host", strprop("host the issue concerns (null/empty clears)")
          s.field "flow_id", intprop("seed flow (null clears); the previous one stays linked")
          s.field "repeater_id", intprop("repeater id to link")
        end

        tool j, "delete_issue",
          "Delete an issue and its links. Setting status resolved/false-positive instead KEEPS " \
          "it in the report." do |s|
          s.field "id", intprop("issue id"), required: true
        end
      end
    end
  end
end
