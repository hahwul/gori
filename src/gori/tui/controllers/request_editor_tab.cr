module Gori::Tui
  # The request-editor half RepeaterController and FuzzerController share word for word: a
  # session view with a TARGET row over a multi-line, §-marker-aware editor. An includer
  # supplies `current_view`; the view answers the pane/selection/marker calls below.
  module RequestEditorTab
    # The space menu's CONTEXT section: whichever pane the active session is focused on.
    # :common with no session open (empty state).
    def command_section : Symbol
      current_view.try(&.focus) || :common
    end

    # Cross-tab "Insert OAST payload": drop the URL at the editor caret.
    def insert_oast_payload(url : String) : Bool
      (v = current_view) ? v.insert_oast_payload(url) : false
    end

    # The pane's own INS/READ mode, asked of the view (`pane_insert?` also answers true for the
    # Repeater's HEX editor and its gRPC field form). Broader than `editor_captures_tab?`,
    # which is false on the single-line TARGET/SNI field — where a digit is very much a
    # character, ports being what they are.
    def body_takes_text? : Bool
      v = current_view
      return false unless v
      v.pane_insert?(v.focus)
    end

    # ^S on the TARGET pane: edit the TLS SNI the session presents, leaving the dialed host
    # alone. One chord, focus rule and status wording on both tabs — a fuzz session seeded
    # from History (⇧I) could otherwise never set one, so an https vhost sweep always
    # presented the dialed IP.
    def toggle_sni : Nil
      if (view = current_view) && view.focus == :target
        view.toggle_sni_field
        @host.status(view.editing_sni? ? "SNI override: type a domain · ^S/↵/esc back to URL" : "editing target URL")
      else
        @host.status("SNI override (^S) applies to the TARGET pane — ↹ to it")
      end
    end

    # Strip every §…§ marker (and its chain). Space-menu only on both tabs — `^U`
    # pretty-prints.
    def clear_marks : Nil
      return unless view = current_view
      @host.status(view.clear_marks)
    end

    # READ-mode copy: the selection (or current line), and the whole focused pane.
    def copy : Nil
      v = current_view
      return unless v
      text = v.pane_copy_text
      return if text.empty?
      copy_text(text)
    end

    def copy_all : Nil
      v = current_view
      return unless v
      text = v.pane_copy_all_text
      return if text.empty?
      copy_text(text, "all")
    end

    # The focused pane's selection (or current line) text without copying — for the
    # "Send selection to" flow.
    def selection_text : String
      (v = current_view) ? v.pane_copy_text : ""
    end

    def selection_active? : Bool
      current_view.try(&.pane_selection?) == true
    end

    def select_line : Nil
      current_view.try(&.pane_select_line)
    end

    def clear_selection : Nil
      current_view.try(&.pane_clear_selection)
    end

    # --- mouse drag + double-click (see TabController#supports_drag?) ---
    def supports_drag? : Bool
      !current_view.nil?
    end

    def focus_resume : Nil
      current_view.try(&.focus_resume)
    end

    def editor_text_buffer : {TextArea, TextReadState}?
      current_view.try(&.read_edit_buffer)
    end

    # Esc over a READ selection: the TARGET's lives in the view's `LineFieldRead`, not in a
    # `TextReadState`, so the view's own pane pair answers for every pane here.
    def editor_drop_read_selection : Bool
      return false unless (v = current_view) && v.pane_selection?
      v.pane_clear_selection
      true
    end

    # `⇧A` / `⇧I` on the one-line TARGET: its own End / Home, then INSERT. The multi-line
    # buffer beside it takes the shared path through `editor_text_buffer`.
    def editor_line_insert(dir : Int32) : Bool
      return super unless (v = current_view) && v.focus == :target
      dir < 0 ? v.target_home : v.target_end
      editor_enter_insert
    end

    # A modified ⌫ — delete a WORD. The `char` half is not defensive padding: a terminal sends
    # ⌥⌫ as ESC + 0x7F, and termisu's Alt-prefix branch maps the payload byte through
    # `Key.from_char`, which has no name for DEL — so the event arrives as `Key::Unknown` +
    # Alt carrying DEL rather than as `Key::Backspace`. Reading the char is what makes
    # the chord work on a real terminal; the `backspace?` half covers a terminal (or a
    # keyboard-protocol mode) that does report it as the named key.
    private def word_delete?(ev : Termisu::Event::Key) : Bool
      return false unless ev.ctrl? || ev.alt?
      return true if ev.key.backspace?
      c = ev.char
      !!c && (c == '\u{7F}' || c == '\b')
    end

    # A backspace/forward-delete of a marker delimiter (§/¦) would unbalance the marker
    # and expose its concealed ¦chain. Confirm first; on accept, strip the WHOLE marker
    # down to its raw value. Returns true when it intercepted (a confirm was raised), so
    # the caller skips the plain edit; false to let the edit through.
    private def guard_marker_delete(view, span : {Int32, Int32}?) : Bool
      return false unless span
      n = view.marker_ordinal(span)
      @host.confirm("REMOVE MARKER",
        "Deleting this character breaks marker §#{n}.\nRemove the whole marker and keep only its value?",
        confirm_label: "remove marker", danger: true) do
        view.strip_marker_span(span)
      end
      true
    end
  end
end
