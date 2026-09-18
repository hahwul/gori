# The hosted agent tab (#1093) — verb intents implemented by Tui::Runner (runner/agent.cr).
abstract class Gori::Verb::ExecContext
  # Availability gates the space menu reads. Cheap, no side effects.
  abstract def agent_alive? : Bool   # a child is running (idle or mid-turn)
  abstract def agent_running? : Bool # a turn is in flight
  abstract def agent_pending? : Bool # a permission request is waiting
  abstract def agent_send : Nil
  abstract def agent_interrupt : Nil
  abstract def agent_stop : Nil
  abstract def agent_restart : Nil
  abstract def agent_new : Nil
  abstract def agent_history : Nil
  abstract def agent_permission : Nil
  abstract def agent_copy : Nil
  abstract def agent_fold : Nil
  # Global: a one-line prompt from any tab, sent without switching.
  abstract def agent_ask : Nil
end
