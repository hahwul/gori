# Umbrella for the fuzzer / intruder engine. See src/gori/fuzz/types.cr for the
# module overview. Built on the Replay send engines + the body decoder; no Store /
# TUI dependency, so the one engine drives the TUI tab, `gori run fuzz`, and MCP.
require "./fuzz/types"
require "./fuzz/content_length"
require "./fuzz/template"
require "./fuzz/payload"
require "./fuzz/generator"
require "./fuzz/matcher"
require "./fuzz/engine"
