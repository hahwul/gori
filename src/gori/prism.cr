# Umbrella for the Prism passive + lightweight-active scanner. See src/gori/prism/mode.cr
# for the overview. The engine (mode/issue/passive/active) has NO Store/TUI dependency; only
# the analyzer touches Store + Scope, so the one analyzer drives both the TUI Prism tab and
# headless `gori run capture`.
require "./prism/mode"
require "./prism/issue"
require "./prism/group"
require "./prism/event"
require "./prism/passive"
require "./prism/active"
require "./prism/from_replay"
require "./prism/analyzer"
