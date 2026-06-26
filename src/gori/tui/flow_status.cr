require "./theme"
require "../store"

module Gori::Tui
  # The {label, colour} a flow's status cell shows: ERR/ABT for failed/aborted
  # flows (status 0 would read as a cryptic "0"), else the numeric code — or "···"
  # while still pending — coloured by class. ONE source so the History list, the
  # Comparer flow picker, and the Comparer headers can never drift.
  module FlowStatus
    def self.cell(row : Store::FlowRow) : {String, Color}
      if row.state.error?
        {"ERR", Theme.red}
      elsif row.state.aborted?
        {"ABT", Theme.yellow}
      else
        {row.status.try(&.to_s) || "···", Theme.status_color(row.status)}
      end
    end
  end
end
