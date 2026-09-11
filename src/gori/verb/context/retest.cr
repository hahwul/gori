# An Issue's retest (#1036) — verb intents implemented by Tui::Runner.
abstract class Gori::Verb::ExecContext
  abstract def issue_retest_available? : Bool
  abstract def issue_retest : Nil
end
