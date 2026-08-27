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

  # The AGENTS card. Reads its rows through an injected probe (a fresh `live` scan) so the card
  # re-checks off the filesystem on `r`, not off the possibly-stale poll snapshot.
  def open_agents : Nil
    ov = AgentsOverlay.new(-> { Gori::AgentPresence.live(@session.project.db_path) })
    # Same ordering rule as open_listeners: drop this modal BEFORE raising the palette, via
    # leave_overlay so no pop-back lands on top of it.
    ov.on_palette = -> { leave_overlay; open_palette }
    open_overlay(ov)
  end
end
