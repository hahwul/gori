require "../../agent_presence"
require "../agents_overlay"

# Attached-agent presence (#815) — the `mcp:<client>` top-bar chip and the AGENTS card.
# ExecContext verb implementations; reopens Gori::Tui::Runner (see tui/runner.cr for the loop).
#
# The data is a filesystem read, not a DB read: `AgentPresence.live` scans the project's
# `.agents` marker directory. That is why the poll hook lives OUTSIDE the data_version branch
# in the event loop — a marker appears and vanishes with a process, moving no DB version.
class Gori::Tui::Runner < Gori::Verb::ExecContext
  # Declared here so Runner#initialize need not be touched. The last snapshot the poll took;
  # the chip and the card both read it.
  @agents : Array(Gori::AgentPresence::Entry) = [] of Gori::AgentPresence::Entry

  # Called every DV_POLL_INTERVAL tick. Re-scans and returns true only when the RENDERED chip
  # string changed, so an idle project with a steady agent list does not force a repaint on the
  # timer (the folded-field discipline the clock/resource meter also follow).
  def refresh_agent_presence : Bool
    before = agent_chip
    @agents = Gori::AgentPresence.live(@session.project.db_path)
    agent_chip != before
  end

  # The top-bar chip label — "" when nothing is attached (Chrome drops an empty chip).
  def agent_chip : String
    AgentsOverlay.chip_label(@agents.map(&.client))
  end

  # --- this WINDOW's own marker (#1091) -------------------------------------------------
  # The mirror image of the block above: `gori mcp` announces itself so the TUI can show it,
  # and now the TUI announces itself so `get_current_context` can tell an agent whether the
  # selection it is reading belongs to a window that is still on screen. A separate marker
  # directory (`AgentPresence::TUI_DIR_SUFFIX`), so the `mcp:` chip above cannot start
  # counting us and the picker's parse-free `count` stays exactly as it was.
  @tui_presence : Gori::AgentPresence? = nil

  # Owned by the RUNNER and not by `Session`: `Session.open` also backs headless
  # `gori run capture`, and a marker announced there would tell an agent a TUI window is up
  # when nothing is drawn at all. One Runner is one project visit — the picker leaving and
  # re-entering builds a new one — so the marker's life is exactly "this project is on screen".
  def announce_tui_presence : Nil
    @tui_presence = Gori::AgentPresence.announce(@session.project.db_path,
      client: "gori tui", client_version: Gori::VERSION, read_only: false,
      selection_source: nil, kind: Gori::AgentPresence::KIND_TUI,
      holds_capture: @session.capturing_lock_held?)
  end

  # Keep the marker's capture bit true to `c`, which moves the lock between windows. A no-op
  # unless it actually moved, so an idle project writes nothing — and no heartbeat, because
  # the flock is what says this window is alive.
  def refresh_tui_presence : Nil
    @tui_presence.try(&.update_capture(@session.capturing_lock_held?))
  end

  def release_tui_presence : Nil
    @tui_presence.try(&.close)
    @tui_presence = nil
  end

  # The AGENTS card. Reads its rows through an injected probe (a fresh `live` scan) so the card
  # re-checks off the filesystem on `r`, not off the possibly-stale poll snapshot.
  def open_agents : Nil
    ov = AgentsOverlay.new(-> { Gori::AgentPresence.live(@session.project.db_path) })
    # Same ordering rule as open_listeners: drop this modal BEFORE raising the palette, via
    # leave_overlay so no pop-back lands on top of it.
    ov.on_palette = -> { leave_overlay; open_palette }
    # Message the highlighted agent straight from the card (#1090): drop the modal first
    # (same ordering as on_palette), then raise the one-line prompt for exactly that entry.
    ov.on_tell = ->(entry : Gori::AgentPresence::Entry) {
      leave_overlay
      ids = @active_tab == :history ? history_target_flow_ids : [] of Int64
      prompt_agent_message(entry, ids, @active_tab.to_s)
    }
    open_overlay(ov)
  end
end
