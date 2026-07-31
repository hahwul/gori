require "./types"
require "../token_extract"

module Gori::Sequencer
  # The token extractor moved to `Gori::TokenExtract` when session bindings (#501) became
  # its second consumer — an extract rule finds a value in a response exactly the five ways
  # a sequencer descriptor does, and `sequencer/extract.cr` already carried the note that
  # `Fuzz::Matcher#extract_value` was a third copy of the regex half. The name stays spelled
  # here because the Sequencer's engine, its CLI/MCP surfaces and its specs all say it.
  alias Extract = Gori::TokenExtract
end
