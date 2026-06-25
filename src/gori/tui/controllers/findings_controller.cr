require "json"
require "../tab_controller"
require "../findings_view"
require "../../store"

module Gori::Tui
  # The Findings tab: the triage list + a finding's detail (with an inline notes
  # editor) + Markdown/JSON export. Owns FindingsView. The "new/edit finding" FORM is
  # a shell overlay (@overlay == :finding_new), so it stays in the Runner; the three
  # cross-tab jumps (finding → its flow in History, finding → Replay, new-from-flow)
  # are shell mediators. The inline notes editor is a text sub-mode claimed by the
  # shell before the focus ring (like the History QL bar) and routed here.
  class FindingsController < TabController
    def initialize(host : Host)
      super(host)
      @findings = FindingsView.new
    end

    def view : FindingsView
      @findings
    end

    def tab : Symbol
      :findings
    end

    def command_scope : Verb::Scope
      @findings.detail_open? ? Verb::Scope::FindingsDetail : Verb::Scope::Findings
    end

    def body_badge : Symbol # the inline notes editor captures text; else the list/read-only detail
      @findings.editing_notes? ? :editor : :body
    end

    def body_hint(focus : Symbol) : String
      @findings.detail_open? ? "[ ] sev · { } status · t title · e notes · o flow · r replay · d del · ←/esc back" \
                             : "↑/↓ move · ↵ open · n new · d delete · x export · : cmds · esc tabs"
    end

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      focused = focus == :body
      BodyChrome.framed(screen, rect, focused) { |inner| @findings.render(screen, inner, focused: focused) }
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      inner = rect.inset(1, 1)
      if @findings.detail_open?
        @findings.notes_click_to_cursor(inner, mx, my) if @findings.editing_notes? # place caret in the inline notes editor
        return true
      end
      @host.focus_body
      return true unless idx = @findings.list_row_at(inner, mx, my)
      # SELECT-FIRST (same as History): first click selects, second opens.
      idx == @findings.selected_index ? findings_open : @findings.select_index(idx)
      true
    end

    def handle_wheel(step : Int32) : Bool
      @findings.move(step) unless @findings.detail_open? # detail pane hides the list — don't shift behind it
      true
    end

    # Findings notes inline editor — a text sub-mode the shell claims before the
    # focus ring. Returns true (swallows), mirroring the old `return handle_…`.
    def handle_notes_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      case
      when ev.ctrl? && key.lower_w? then @findings.cancel_notes_edit # discard edits
      when key.escape?              then @findings.save_notes(@host.session.store)
      when key.enter?               then @findings.notes_newline
      when key.backspace?           then @findings.notes_backspace
      when key.up?                  then @findings.notes_move(-1, 0)
      when key.down?                then @findings.notes_move(1, 0)
      when key.left?                then @findings.notes_move(0, -1)
      when key.right?               then @findings.notes_move(0, 1)
      else
        if c && !ev.ctrl? && !ev.alt?
          @findings.notes_insert(c)
          @findings.set_preedit("") # commit any preedit
        end
      end
      true
    end

    # Live IME composition only flows to the inline notes editor.
    def set_preedit(text : String) : Bool
      return false unless @findings.editing_notes?
      @findings.set_preedit(text)
      true
    end

    def on_enter : Nil
      @findings.reload(@host.session.store)
    end

    def on_external_change : Nil
      @findings.reload(@host.session.store)
    end

    def commit : Nil
      @findings.save_notes(@host.session.store) if @findings.editing_notes?
    end

    # --- ExecContext verbs (delegated from the Runner) ---
    def findings_move(delta : Int32) : Nil
      if delta < 0 && @findings.at_top?
        return @host.request_focus(:menu) # ↑ at the top finding pops up to the tab bar
      end
      @findings.move(delta)
    end

    def findings_open : Nil
      @findings.open_detail(@host.session.store)
    end

    def finding_close : Nil
      @findings.close_detail
    end

    def findings_delete : Nil
      return unless f = @findings.target_finding
      @host.confirm("DELETE FINDING", "Delete \"#{f.title}\"?\nThis can't be undone.", confirm_label: "delete", danger: true) do
        @findings.delete(@host.session.store)
        @host.refresh_findings_count
      end
    end

    def finding_severity(delta : Int32) : Nil
      @findings.severity_delta(delta, @host.session.store)
    end

    def finding_status(delta : Int32) : Nil
      @findings.status_delta(delta, @host.session.store)
    end

    def finding_edit_notes : Nil
      @findings.start_notes_edit
    end

    # Write all findings to the project dir as Markdown (the report) or JSON.
    def findings_export(format : Symbol) : Nil
      findings = @host.session.store.findings
      return @host.status("no findings to export") if findings.empty?
      ext = format == :json ? "json" : "md"
      content = format == :json ? findings_json(findings) : findings_markdown(findings)
      path = File.join(@host.session.project.dir, "findings.#{ext}")
      File.write(path, content)
      msg = "exported #{findings.size} finding#{findings.size == 1 ? "" : "s"} → #{path}"
      # A temp project's dir is wiped on close — warn so the report isn't silently lost.
      msg += "  ⚠ temp project — copy it before closing" if @host.session.project.ephemeral?
      @host.status(msg)
    rescue ex
      @host.status("export failed: #{ex.message}")
    end

    private def findings_markdown(findings : Array(Store::Finding)) : String
      store = @host.session.store
      String.build do |io|
        io << "# Findings — " << @host.session.project.name << "\n\n"
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

    private def append_evidence(io : String::Builder, label : String, head : Bytes?, body : Bytes?) : Nil
      return unless head && !head.empty?
      cap = 64 * 1024
      io << "\n### " << label << "\n\n```http\n"
      # HEAD: headers are text but can carry stray non-UTF-8 (obs-text) bytes — scrub
      # them so the report stays a valid UTF-8 file; cap it like the body.
      hslice = head.size > cap ? head[0, cap] : head
      io << String.new(hslice).scrub
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

    private def findings_json(findings : Array(Store::Finding)) : String
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
  end
end
