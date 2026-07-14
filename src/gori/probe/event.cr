module Gori
  module Probe
    # Analyzer → TUI events (the controller drains these in the run loop). All are
    # best-effort/droppable so a headless run with no drainer never blocks the analyzer.
    #
    # IssueEvent fires once per analyzed flow that produced ≥1 issue; the controller
    # coalesces them into a single list reload per frame. When `summary` is set (an active
    # reflection was confirmed) the controller also raises a notification.
    record IssueEvent, host : String, summary : String? = nil
    record ErrorEvent, message : String

    alias Event = IssueEvent | ErrorEvent
  end
end
