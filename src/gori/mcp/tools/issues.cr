require "json"
require "../../store"
require "../serialize"
require "../../env"

module Gori
  module MCP
    class Tools
      private def list_issues(h) : Result
        req_off = int(h, "offset")
        req_lim = int(h, "limit")
        offset = clamp_nonneg(req_off)
        limit = clamp(req_lim, 100, 500)
        all = @store.issues
        page = all[offset, limit]? || [] of Store::Issue
        Result.new(JSON.build do |j|
          j.object do
            j.field("issues") { j.array { page.each { |f| Serialize.issue(j, f, @store) } } }
            j.field "returned", page.size
            j.field "offset", offset
            j.field "limit", limit
            emit_clamp(j, req_off, offset, req_lim, limit)
            j.field "total", all.size
            j.field "has_more", offset + page.size < all.size
          end
        end)
      end

      private def get_issue(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        f = @store.get_issue(id)
        return not_found("no issue with id #{id}") unless f
        Result.new(JSON.build { |j| Serialize.issue(j, f, @store) })
      end

      private def create_issue(h) : Result
        title = str(h, "title")
        return Result.new("missing required 'title'", is_error: true) if title.nil? || title.empty?
        # Mask secrets in issue title
        masked_title = Env.mask_secrets(title)

        # An unrecognised severity is rejected, not silently coerced to Info —
        # matching update_issue (a typo'd 'severity' shouldn't quietly become
        # an info issue). An absent/blank severity still defaults to Info.
        sev_s = str(h, "severity")
        if err = bad_severity(sev_s)
          return err
        end
        severity = severity_from(sev_s) || Store::Severity::Info
        # A present-but-invalid flow_id (1.9 / "oops") would otherwise be
        # silently nulled, creating an UNLINKED issue while reporting success —
        # reject it, consistent with how get_flow rejects a non-integer id.
        flow_id = int(h, "flow_id")
        return Result.new("invalid 'flow_id' (expected an integer)", is_error: true) if flow_id.nil? && present?(h, "flow_id")
        repeater_id = int(h, "repeater_id")
        return Result.new(id_error(h, "repeater_id"), is_error: true) if repeater_id.nil? && present?(h, "repeater_id")
        if repeater_id && !@store.get_repeater(repeater_id)
          return not_found("no repeater with id #{repeater_id}")
        end

        host = str(h, "host").try { |hst| Env.mask_secrets(hst) }
        id = @store.insert_issue(masked_title, severity, host, flow_id)
        # insert_issue returns 0 (never raises) when the write batch fails — e.g.
        # the cross-process SQLite lock couldn't be acquired (a TUI capturing into
        # the same project) or the disk is full. Don't report a phantom success.
        return busy("failed to persist issue (store busy or unwritable)") if id == 0
        if repeater_id
          @store.add_link(Store::LinkOwnerKind::Issue, id,
            Store::LinkRefKind::Repeater, repeater_id)
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "repeater_id", repeater_id if repeater_id
          end
        end)
      end

      private def update_issue(h) : Result
        id = int(h, "id")
        return Result.new(id_error(h, "id"), is_error: true) unless id
        return not_found("no issue with id #{id}") unless @store.get_issue(id)
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

        title = str(h, "title").try { |t| Env.mask_secrets(t) }
        return Result.new("title must not be empty", is_error: true) if title && title.empty?
        notes = str(h, "notes").try { |n| Env.mask_secrets(n) }
        severity = severity_from(sev_s)
        status = status_from(stat_s)
        repeater_id = int(h, "repeater_id")
        return Result.new(id_error(h, "repeater_id"), is_error: true) if repeater_id.nil? && present?(h, "repeater_id")
        if repeater_id && !@store.get_repeater(repeater_id)
          return not_found("no repeater with id #{repeater_id}")
        end

        # Don't claim updated:true on a no-op. With no resolvable field the store
        # write is a silent no-op, so returning success would mislead the caller
        # (e.g. it'd think a typo'd field name took effect).
        if title.nil? && severity.nil? && notes.nil? && status.nil? && repeater_id.nil?
          return Result.new("no fields to update (provide at least one of title/severity/notes/status)", is_error: true)
        end

        unless title.nil? && severity.nil? && notes.nil? && status.nil?
          @store.update_issue(id, title: title, severity: severity, notes: notes, status: status)
        end
        if repeater_id
          @store.add_link(Store::LinkOwnerKind::Issue, id,
            Store::LinkRefKind::Repeater, repeater_id)
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "id", id
            j.field "updated", true
            j.field "repeater_id", repeater_id if repeater_id
          end
        end)
      end
    end
  end
end
