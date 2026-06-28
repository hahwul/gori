# Umbrella for the parameter-mining ("Param Miner") engine. See src/gori/miner/types.cr
# for the overview. Built on the Replay send engines (via the reused Fuzz::Sender) + the
# body decoder + Fuzz::ContentLength; no Store / TUI dependency, so the one engine drives
# the TUI Miner tab, `gori run mine`, and the MCP mine_* tools.
require "./miner/types"
require "./miner/wordlist"
require "./miner/inject"
require "./miner/detect"
require "./miner/fingerprint"
require "./miner/baseline"
require "./miner/engine"
