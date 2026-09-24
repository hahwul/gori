require "./theme"
require "../store"

module Gori::Tui
  # The {label, colour} a flow's status cell shows: ERR/ABT for failed/aborted
  # flows (status 0 would read as a cryptic "0"), else the numeric code — or "···"
  # while still pending — coloured by class. ONE source so the History list, the
  # Comparer flow picker, the Comparer headers and the picker's cross-project search can never
  # drift.
  module FlowStatus
    def self.cell(row : Store::FlowRow) : {String, Color}
      cell(row.status, row.state)
    end

    # The same cell off the two columns alone, for a row that is not a `FlowRow` (a
    # `ProjectSearch::Hit` read from another project's database). `state` is nil there when the
    # stored integer is one this build has no member for, which reads as its status code.
    def self.cell(status : Int32?, state : Store::FlowState?) : {String, Color}
      if state.try(&.error?)
        {"ERR", Theme.red}
      elsif state.try(&.aborted?)
        {"ABT", Theme.yellow}
      else
        {status.try(&.to_s) || "···", Theme.status_color(status)}
      end
    end
  end
end
