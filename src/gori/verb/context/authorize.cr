# Authorize (access-control / multi-identity replay) — verbs, reopens
# Gori::Verb::ExecContext (see verb/context.cr for the full facade and this convention).
abstract class Gori::Verb::ExecContext
  # CROSS-TAB seeding: load captured requests into the Authorize tab's queue (and jump there).
  abstract def authorize_seed_selected : Nil # History's selected (or marked) flows
  abstract def authorize_seed_sitemap : Nil  # the Sitemap cursor's representative capture

  # The three run modes over the queue. Pending is the incremental default — an operator builds
  # the queue up over a session and scans between additions, so re-sending rows that already
  # have a result is wasted traffic against the target.
  abstract def authorize_run : Nil     # every request with no result yet
  abstract def authorize_run_all : Nil # every request, re-running the ones already done
  abstract def authorize_run_one : Nil # the cursor request alone

  abstract def authorize_stop : Nil   # ask the in-flight run to stop
  abstract def authorize_remove : Nil # drop the cursor request from the queue
  abstract def authorize_clear : Nil  # empty the queue

  # Open the identity list — who the queue is replayed as. The set persists per project.
  abstract def authorize_identities : Nil

  # Flip unattended replay: authenticated GETs are queued and replayed as they are captured.
  abstract def authorize_toggle_passive : Nil
  abstract def authorize_passive? : Bool

  # A request is queued — the gate for run/remove/clear.
  abstract def authorize_has_target? : Bool
  # A run is in flight — gates Stop, and hides the run verbs while one is going.
  abstract def authorize_running? : Bool
end
