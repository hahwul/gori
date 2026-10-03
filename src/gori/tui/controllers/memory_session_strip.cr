module Gori::Tui
  # The in-memory sub-tab strip the Decoder, the Comparer and the JWT/Cookie workbenches share:
  # `@sessions` (never empty) and `@idx`, the strip and filter flags, ←/→ and ^1-9 nav, the
  # duplicate and close arms (the plural one confirm-gated, the last session kept), rename and
  # the mark ref. A session answers `view`; the Comparer's sessions ARE views, so it overrides
  # `view_at` and `session_label`.
  module MemorySessionStrip
    # Hooks an includer supplies (declared by name rather than `abstract def`, because the
    # workbench includer is generic — see the note above `WorkbenchController#render_shell`):
    #   `blank_session(old)` — the session that replaces `old` when the LAST one closes, so the
    #     tab always keeps something to type into;
    #   `session_summary(s)` — the chip label when the session has no custom name;
    #   `duplicate_at(idx)` — clone sub-tab `idx` onto the end of the strip, toast-free.

    # Hook: the session set changed (new, duplicate, close). The Decoder closes its chain popup
    # and marks the set for persisting here.
    private def after_change : Nil
    end

    # --- sub-tab strip (runner-owned chrome; shown from the first session) ---
    def subtab_labels : Array(String)
      @sessions.map_with_index { |s, i| "#{i + 1}:#{session_label(s)}" }
    end

    def subtab_index : Int32
      @idx
    end

    # Show the strip from the FIRST session (not ≥2), like Repeater/Notes: a lone session
    # still labels its chip and exposes the strip's space-menu.
    def subtab_strip_shown? : Bool
      true
    end

    # --- sub-tab filter (issue #121) ---
    def subtab_filter_enabled? : Bool
      true
    end

    # The chip label: the custom name, else the tool's summary, capped ~18 cols.
    private def session_label(s) : String
      raw = (n = s.view.name) ? n : session_summary(s)
      raw.size > 18 ? raw[0, 17] + "…" : raw
    end

    # Filter-aware strip nav: ←/→ skip hidden chips; ^1-9 to a hidden chip drops the filter
    # (chip numbers are absolute). Sessions live in memory, so switching loses nothing.
    def move_subtab(dir : Int32) : Nil
      if t = step_visible(@idx, dir)
        switch_to(t)
      end
    end

    def jump_subtab(idx : Int32) : Nil
      return unless 0 <= idx < @sessions.size
      clear_subtab_filter if (h = subtab_hidden) && h.includes?(idx)
      switch_to(idx) if idx != @idx
    end

    private def switch_to(idx : Int32) : Nil
      @idx = idx
    end

    # --- session lifecycle ---
    # Duplicates the MARKED sub-tabs when the strip carries marks, the active one otherwise
    # (`target_subtab_indices` — the one target rule). `single` is the one-clone toast.
    private def duplicate_sessions(noun : String, single : String) : Nil
      msg = nil.as(String?)
      if refs = batch_subtab_refs
        return unless msg = duplicate_marked_subtabs(refs, noun) { |i| duplicate_at(i) }
      else
        duplicate_at(@idx)
      end
      after_change
      @host.request_focus(:body)
      @host.status("#{msg || single} (#{@sessions.size} open)")
    end

    # ^W closes the MARKED sub-tabs when the strip carries marks, the active one otherwise
    # (`target_subtab_indices` — the one target rule). The single close stays confirm-free as
    # it has always been; a plural one asks, because it discards more than the operator can
    # see at the moment they press the key. `cleared` toasts closing the last session (which
    # leaves a blank one), `closed` every other close.
    private def close_sessions(title : String, discarded : String, cleared : String, closed : String) : Nil
      if refs = batch_subtab_refs
        @host.confirm(title, "Close #{marked_subtab_phrase(refs.size)}?\n#{discarded}",
          confirm_label: "close", danger: true) { close_marked_sessions(refs) }
        return
      end
      close_at(@idx)
      after_change
      @host.status(@sessions.size == 1 ? cleared : "#{closed} (#{@sessions.size} open)")
    end

    private def close_marked_sessions(refs : Array(SubtabRef)) : Nil
      msg = close_marked_subtabs(refs)
      after_change
      @host.status(msg)
      @host.resolve_subtab_focus
    end

    # Nothing here is persisted, so a close can never leave a saved session behind.
    protected def close_subtab_at(idx : Int32) : Bool
      close_at(idx)
      false
    end

    # Close sub-tab `idx`, keeping at least one session: the last one is REPLACED by
    # `blank_session` rather than removed.
    private def close_at(idx : Int32) : Nil
      return if idx < 0 || idx >= @sessions.size
      if @sessions.size <= 1
        @sessions[0] = blank_session(@sessions[0])
        @idx = 0
      else
        @sessions.delete_at(idx)
        # Closing a session to the LEFT slides the active one down; a bare clamp would read
        # that as "stay put" and land the operator on its neighbour.
        @idx -= 1 if idx < @idx
        @idx = @idx.clamp(0, @sessions.size - 1)
      end
    end

    # The session's view, for the rename prompt (re-found by view identity).
    def view_at(idx : Int32)
      (0 <= idx < @sessions.size) ? @sessions[idx].view : nil
    end

    # The object that IS sub-tab `idx`, for the strip's mark set (#683). The view, not the
    # index: a reconcile can reorder or drop chips under a standing mark.
    def subtab_ref(idx : Int32) : SubtabRef?
      view_at(idx)
    end

    # Apply a typed name to the captured sub-tab's view (the prompt held it by identity, so
    # mutating it is inherently the right session). Blank clears it (the chip reverts to the
    # auto label).
    def apply_rename(view, name : String) : Nil
      view.name = name.strip.presence
    end
  end
end
