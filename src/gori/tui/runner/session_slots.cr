# Session slots — picking WHICH identity the next send goes out as. ExecContext verb
# implementations; reopens Gori::Tui::Runner (see tui/runner.cr for the event loop).
#
# The LIST is edited in the Authorize tab's identities card (`runner/authorize.cr`) — an
# Authorize identity IS a session slot, one list and one settings row. What lives here is the
# other half: the ACTIVE pointer, which is what `Repeater::Sender`, `Fuzz::Sender` and the
# intercept forward consult through `Env.overlay_slot`, and which the `session:` top-bar chip
# reports. It is memory-only by design (`SessionSlots`), so this writes nothing.
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # The picker. A `LibraryPicker` rather than a card of its own: it is exactly that shape — a
  # filterable name + detail list whose `on_commit` is injected by the open-site — and a slot
  # list can be long enough that typing two letters of the name beats scrolling.
  #
  # Row 0 is ALWAYS `as captured`, even when the project has no slots. It is not a placeholder:
  # deactivating is the way back to sending a request under its own session, and a picker that
  # can only ever ADD an overlay would leave the operator no way out but restarting gori.
  def open_session_slots : Nil
    registry = @session.slots
    list = registry.slots
    active = registry.active_name
    lp = LibraryPicker.new("SESSION SLOT", session_slot_rows(list, active), "session slot", "activate")
    lp.on_commit = -> {
      # Index against the SAME array the rows were built from, and by NAME rather than by
      # position: the list can be edited from the Authorize card, `gori run session` or MCP
      # between this card opening and ↵, and activating "whatever is third now" would send
      # the wrong identity's credential.
      if i = lp.selected_index
        activate_session_slot(registry, i == 0 ? nil : list[i - 1]?.try(&.name))
      end
      true
    }
    # ^R refreshes the row under the cursor (#1233). A chord and not the issue's bare `r`:
    # every printable key in this card types into its search box.
    lp.on_refresh = ->(i : Int32) {
      if slot = (i == 0 ? nil : list[i - 1]?)
        refresh_session_slot(slot.name)
      else
        @toast = "as captured has nothing to refresh — pick a slot"
      end
      nil
    }
    open_overlay(lp)
  end

  # Run a slot's refresh on its own fiber (#1233) — the steps are network sends, and the
  # event loop must keep painting the `⟳` chip while they run. The outcome comes back through
  # `SessionRefresh::Runner#take_outcomes`, drained on the tick by `drain_session_refreshes`,
  # which is where the toast is raised.
  def refresh_session_slot(name : String) : Nil
    slot = @session.slots.find(name)
    return (@toast = "session slot #{name.inspect} is gone") unless slot
    unless slot.refreshable?
      return (@toast = "#{name} has no refresh steps — add one from a Repeater sub-tab (space → b)")
    end
    runner = @session.refresher
    return (@toast = "refreshing #{name}…") if runner.refreshing?(name)
    @toast = "refreshing #{name}…"
    spawn(name: "gori-session-refresh") do
      runner.refresh(name)
    rescue ex
      ::Log.warn { "session refresh #{name} raised: #{ex.message}" }
    end
  end

  # The Repeater's "Use as refresh for slot…" (#1233): pick a slot, append the active sub-tab.
  # The tab is SAVED first, so the step the slot records is the request on screen and not
  # whatever the row held before the last edit.
  def repeater_use_as_refresh : Nil
    return unless @active_tab == :repeater
    repeater_controller.save_current_repeater
    id = repeater_controller.current_session_db_id
    return (@toast = "this sub-tab is not saved to the project (WebSocket/gRPC-binary tabs are session-only)") unless id
    # A save the store refused leaves the tab dirty, and the row still holds the request from
    # before the edit — appending its id now would refresh with bytes that are not on screen.
    if repeater_controller.current_session_dirty?
      return (@toast = "this sub-tab's edits are not saved (project busy) — nothing was changed, try again")
    end
    registry = @session.slots
    list = registry.slots
    return (@toast = "no session slots yet — add one in the Authorize tab's identities card") if list.empty?
    rows = list.map_with_index do |slot, i|
      steps = Gori::SessionRefresh.step_labels(@session.store, slot)
      detail = steps.empty? ? "no refresh steps" : "refresh: #{steps.join(" → ")}"
      detail = "already a step · #{detail}" if slot.refresh.includes?(id)
      LibraryPicker::Row.new(i, slot.name, detail)
    end
    lp = LibraryPicker.new("USE AS REFRESH FOR SLOT", rows, "session slot", "append")
    lp.on_commit = -> {
      if (i = lp.selected_index) && (slot = list[i]?)
        append_refresh_step(registry, slot.name, id)
      end
      true
    }
    open_overlay(lp)
  end

  private def append_refresh_step(registry : Gori::SessionSlots, name : String, id : Int64) : Nil
    unless registry.find(name)
      return (@toast = "session slot #{name.inspect} is gone — nothing was changed")
    end
    unless registry.append_refresh(name, id)
      return (@toast = "the project is busy — #{name}'s refresh steps are unchanged")
    end
    steps = registry.find(name).try { |s| Gori::SessionRefresh.step_labels(@session.store, s) } || [] of String
    @toast = "#{name} refreshes with #{steps.join(" → ")}"
  end

  # Drain finished refreshes into toasts (#1233), from the tick. Success reads
  # `refreshed admin · $BIND.TOKEN rebound (eyJh…Q9x2)`; a failure is also a notification,
  # because a refresh gori ran on its own before a send is traffic the operator did not type
  # and a failed one is the thing they have to hear about. The preview is `mask_preview` —
  # never the value.
  def drain_session_refreshes : Bool
    outcomes = @session.refresher.take_outcomes
    return false if outcomes.empty?
    outcomes.each do |o|
      if o.ok
        @toast = session_refresh_toast(o)
      else
        @toast = o.message
        @notifications.push(:warn, o.message, source: "session")
      end
    end
    true
  end

  private def session_refresh_toast(o : Gori::SessionRefresh::Outcome) : String
    return o.message if o.rebound.empty?
    rows = @session.bindings.rows.select { |r| r.slot == o.slot && o.rebound.includes?(r.name) }
    previews = rows.map { |r| "#{Gori::Env.spell(r.name, Gori::Env::Namespace::Bind)} (#{r.preview})" }
    "refreshed #{o.slot} · #{previews.join(", ")} rebound"
  end

  # `as captured` first, then one row per slot. The detail column is the overlay SUMMARY —
  # header names only, never values, the same rule the identities card renders under (a
  # session cookie painted on screen is a credential anyone glancing at the terminal has).
  private def session_slot_rows(list : Array(Gori::SessionSlot),
                                active : String?) : Array(LibraryPicker::Row)
    rows = [LibraryPicker::Row.new(0, "as captured",
      session_slot_detail("the request's own session — no overlay", active.nil?))]
    list.each_with_index do |slot, i|
      detail = slot.rules.empty? ? slot.summary : "#{slot.summary} · rules #{Gori::Env.token_list(slot.rules, ns: Gori::Env::Namespace::Bind)}"
      detail = "#{detail} · #{session_slot_refresh_detail(slot)}"
      rows << LibraryPicker::Row.new(i + 1, slot.name, session_slot_detail(detail, slot.name == active))
    end
    rows
  end

  # `refresh 2 steps · before jwt-exp · bound 12m ago`, or `no refresh`.
  private def session_slot_refresh_detail(slot : Gori::SessionSlot) : String
    return "no refresh" unless slot.refreshable?
    n = slot.refresh.size
    parts = ["refresh #{n} step#{n == 1 ? "" : "s"}"]
    parts << "before #{slot.refresh_before}" unless slot.refresh_before.off?
    newest = @session.bindings.rows.select { |r| r.slot == slot.name }.compact_map(&.bound_at).max?
    parts << "bound #{session_slot_age(newest)} ago" if newest
    st = @session.refresher.status(slot.name)
    parts << "last refresh failed" if st.failed?
    parts << "auto refresh off" if st.auto_off
    parts.join(" · ")
  end

  private def session_slot_age(at : Time) : String
    s = (Time.utc - at).total_seconds.to_i
    return "#{s}s" if s < 60
    return "#{s // 60}m" if s < 3600
    "#{s // 3600}h"
  end

  private def session_slot_detail(text : String, active : Bool) : String
    active ? "● active · #{text}" : text
  end

  # Select (or clear) the send context and SAY so. The toast is not decoration: an overlay
  # changes bytes on every later send and is invisible in the Repeater's own editor, so the
  # moment it is switched is the one place the TUI can name it. The `session:` chip carries it
  # from then on.
  private def activate_session_slot(registry : Gori::SessionSlots, name : String?) : Nil
    unless registry.activate(name)
      # The slot was deleted between the card opening and ↵. Reported rather than swallowed:
      # a silent no-op leaves the previous identity active while the operator believes they
      # switched.
      @toast = "session slot #{name.inspect} is gone — the send context is unchanged"
      return
    end
    @toast = name ? "sending as #{name}" : "sending as captured — no header overlay"
  end

  # The `session:NAME` top-bar chip's label, or "" when no slot is active. Empty is the
  # default and stays chipless on purpose: as-captured is what gori has always done, and a
  # chip that is only ever there while an overlay is in force makes its APPEARANCE the signal.
  #
  # `session:admin ⟳` while the active slot is refreshing, `session:admin !` after its last
  # refresh failed (#1233) — the one place a refresh gori ran on its own before a send shows
  # up without a toast.
  def session_slot_chip : String
    return "" unless name = @session.slots.active_name
    st = @session.refresher.status(name)
    return "session:#{name} ⟳" if st.refreshing
    return "session:#{name} !" if st.failed? || st.auto_off
    "session:#{name}"
  end
end
