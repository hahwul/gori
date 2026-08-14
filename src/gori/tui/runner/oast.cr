# OAST out-of-band listener — ExecContext verb implementations, reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # Both of these act on exactly ONE provider, and the provider bar's "All" position names
  # none. Where that is genuinely ambiguous — two or more providers enabled — ask with a card
  # instead of refusing with a status line; the controller resolves the unambiguous cases
  # (none enabled, exactly one) itself. Same picker, different commit.
  def oast_listen : Nil
    return if pick_oast_provider("START LISTENING WITH") { |key| oast_controller.start_listening_with(key) }
    oast_controller.start_listening_action
  end

  def oast_stop : Nil
    oast_controller.stop_listening
  end

  def oast_generate : Nil
    return if pick_oast_provider("GET PAYLOAD FROM") { |key| oast_controller.generate_payload_with(key) }
    oast_controller.generate_payload
  end

  # Open PICK A PROVIDER when the action has more than one candidate, answering whether it
  # did. The picker stays a dumb list — the open-site injects what ↵ means, per the Overlay
  # seam — and the commit lands back in the controller, which owns the pick and every listener.
  #
  # `action` answers whether the pick RESOLVED, and that Bool is the shell's close signal
  # (overlay.cr: a false commit keeps the form up). A row can go stale while the card is open —
  # a peer process disabling that provider is enough — and closing onto "that provider is gone"
  # would leave the operator with the refusal and nothing left to pick from.
  private def pick_oast_provider(title : String, &action : String -> Bool) : Bool
    return false unless oast_controller.provider_pick_needed?
    rows = oast_controller.provider_pick_rows
    return false if rows.empty?
    picker = OastProviderPicker.new(rows, title)
    picker.on_commit = -> {
      row = picker.selected_row
      row ? action.call(row.key) : true
    }
    open_overlay(picker)
    true
  end

  def oast_copy : Nil
    oast_controller.copy_payload
  end

  def oast_filter : Nil
    oast_controller.start_cb_filter
  end

  # Open RESUME LISTENER over this project's persisted sessions. The open-site injects both
  # actions (↵ resume, `x` release) so the picker itself stays a dumb list, per the Overlay
  # seam — and both land back in the controller, which owns every listener.
  def oast_sessions : Nil
    rows = oast_controller.session_rows
    if rows.empty?
      @toast = "no OAST sessions yet — start one with ^R"
      return
    end
    picker = OastSessionPicker.new(rows)
    picker.on_commit = -> {
      picker.selected_row.try { |row| oast_controller.resume_session(row.session_id) }
      true
    }
    picker.on_release = ->(session_id : Int64) { oast_controller.release_session(session_id) }
    open_overlay(picker)
  end

  def oast_callback_selected? : Bool
    oast_controller.callback_selected?
  end

  # File the selected callback as an Issue, its raw interaction carried in as the notes. High
  # by default, not the form's Medium: a callback is not a suspicion — the target's own
  # infrastructure reached a server it was never given a reason to reach. Tab re-rates it.
  def oast_issue_create : Nil
    draft = oast_controller.callback_issue_draft
    unless draft
      @toast = "no callback selected"
      return
    end
    open_issue_form(IssueForm.new(draft.title, draft.host,
      severity: Store::Severity::High, notes: draft.notes))
  end

  def oast_add_provider : Nil
    oast_controller.open_add_provider
  end

  def oast_edit_provider : Nil
    oast_controller.open_edit_provider
  end

  def oast_toggle_provider : Nil
    oast_controller.toggle_provider
  end

  def oast_delete_provider : Nil
    oast_controller.delete_provider
  end

  def oast_payload_available? : Bool
    oast_controller.has_active_listener?
  end

  def oast_insert_payload : Nil
    url = oast_controller.generate_for_insert
    unless url
      @toast = "no OAST listener — start one in the OAST tab (^R)"
      return
    end
    ok = case @active_tab
         when :repeater then repeater_controller.insert_oast_payload(url)
         when :fuzzer   then fuzzer_controller.insert_oast_payload(url)
         else                false
         end
    @toast = ok ? "inserted OAST payload: #{url}" : "focus the request/template editor first"
  end

  def oast_copy_payload : Nil
    url = oast_controller.generate_for_insert
    unless url
      @toast = "no OAST listener — start one in the OAST tab (^R)"
      return
    end
    Clipboard.copy(url)
    @toast = "copied OAST payload: #{url}"
  end

  # A callback's detail is open — the gate for its read verbs.
  def oast_detail_readable? : Bool
    oast_controller.oast_detail_readable?
  end
end
