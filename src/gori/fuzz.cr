# Umbrella for the fuzzer / intruder engine. See src/gori/fuzz/types.cr for the
# module overview. Built on the Repeater send engines + the body decoder. The engine remains
# surface-neutral; persistence is an opt-in adapter over Store shared by TUI, CLI, and MCP.
require "./fuzz/types"
require "./fuzz/content_length"
require "./fuzz/template"
require "./fuzz/ws_script"
require "./fuzz/payload"
require "./fuzz/presets"
require "./fuzz/auto_encode"
require "./fuzz/generator"
require "./fuzz/matcher"
require "./fuzz/grpc_fields"
require "./fuzz/engine"
require "./fuzz/plan"
require "./fuzz/history_record"
require "./fuzz/persistence"
require "./fuzz/spool"
