require "../../src/gori/tui/controllers/history_controller"

# Drive the same completion/debounce/capture ticks as Runner. The deadline is a
# deadlock guard, not a timing assertion; performance belongs in the benchmark.
def settle_history(controller : Gori::Tui::HistoryController, store : Gori::Store? = nil) : Nil
  deadline = Time.instant + 10.seconds
  loop do
    controller.flush_query_reload_if_due(Time.instant + 1.second)
    controller.view.flush_filter(store) if store
    break unless controller.view.searching?
    raise "History search did not settle" if Time.instant >= deadline
    Fiber.yield
  end
end
