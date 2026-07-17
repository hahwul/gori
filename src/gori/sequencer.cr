# Umbrella for the token-randomness analyzer ("Sequencer"). See
# src/gori/sequencer/types.cr for the overview. Built on the reused Fuzz::Sender send
# seam + the body decoder; no Store / TUI dependency, so the one engine drives the TUI
# Sequencer tab, `gori run sequence`, and the MCP sequence_* tools.
require "./sequencer/types"
require "./sequencer/extract"
require "./sequencer/stats"
require "./sequencer/present"
require "./sequencer/engine"
