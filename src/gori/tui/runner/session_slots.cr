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
    open_overlay(lp)
  end

  # `as captured` first, then one row per slot. The detail column is the overlay SUMMARY —
  # header names only, never values, the same rule the identities card renders under (a
  # session cookie painted on screen is a credential anyone glancing at the terminal has).
  private def session_slot_rows(list : Array(Gori::SessionSlot),
                                active : String?) : Array(LibraryPicker::Row)
    rows = [LibraryPicker::Row.new(0, "as captured",
      session_slot_detail("the request's own session — no overlay", active.nil?))]
    list.each_with_index do |slot, i|
      detail = slot.rules.empty? ? slot.summary : "#{slot.summary} · rules #{Gori::Env.token_list(slot.rules)}"
      rows << LibraryPicker::Row.new(i + 1, slot.name, session_slot_detail(detail, slot.name == active))
    end
    rows
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
  def session_slot_chip : String
    (name = @session.slots.active_name) ? "session:#{name}" : ""
  end
end
