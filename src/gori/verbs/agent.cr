require "../verb"

module Gori
  module Verbs
    # The Agent tab (#1093): a coding agent hosted as a child process, drawn in the tab.
    #
    # Chords are chosen against three neighbours at once. The input pane is an EDITOR pane, so
    # `Scope::Editor` is consulted ahead of this scope while it is focused — none of these
    # reuse its `i` / `↵` / `esc` / `^Z` / `^G` / `^F`. `Scope::Global` backs both, and its
    # bare `s` / `c` / `i` would be SHADOWED by a same-letter chord here (the registry's
    # `validate_chords!` catches duplicates within a scope, not across), so none of these use
    # them either. `^↵` cannot be a chord at all (`Verb::Reserved` refuses `^M`); `^S` is the
    # send key the Repeater and Fuzzer already teach.
    def self.register_agent(r : Verb::Registry) : Nil
      alive = ->(ctx : Verb::ExecContext) { ctx.agent_alive? }
      running = ->(ctx : Verb::ExecContext) { ctx.agent_running? }
      pending = ->(ctx : Verb::ExecContext) { ctx.agent_pending? }

      r.register Verb::Definition.new(
        "agent.send", "Send", "Send the input pane as the next turn (starts the agent if needed)",
        Verb::Scope::Agent, [Verb::Chord.new("s", ctrl: true)],
        mnemonic: 's', group: :send) { |ctx| ctx.agent_send; nil }

      r.register Verb::Definition.new(
        "agent.interrupt", "Stop this turn", "Cancel the running turn; the agent keeps its context",
        Verb::Scope::Agent, [Verb::Chord.new("x", ctrl: true)],
        available: running, mnemonic: 'x', group: :send) { |ctx| ctx.agent_interrupt; nil }

      r.register Verb::Definition.new(
        "agent.permission", "Answer permission", "Open the held tool call's allow / deny card",
        Verb::Scope::Agent, [Verb::Chord.new("p")],
        available: pending, mnemonic: 'p', group: :send) { |ctx| ctx.agent_permission; nil }

      r.register Verb::Definition.new(
        "agent.fold", "Fold / unfold tool call", "Toggle the tool call under the transcript cursor",
        Verb::Scope::Agent, [Verb::Chord.new("f")],
        mnemonic: 'f', group: :view) { |ctx| ctx.agent_fold; nil }

      r.register Verb::Definition.new(
        "agent.history", "Past conversations", "Open an earlier conversation, read-only",
        Verb::Scope::Agent, [Verb::Chord.new("h")],
        mnemonic: 'h', group: :view) { |ctx| ctx.agent_history; nil }

      r.register Verb::Definition.new(
        "agent.copy", "Copy transcript", "Copy the transcript selection, or all of it",
        Verb::Scope::Agent, [Verb::Chord.new("y")],
        mnemonic: 'y', group: :copy) { |ctx| ctx.agent_copy; nil }

      r.register Verb::Definition.new(
        "agent.new", "New conversation", "Start over with a fresh child and an empty transcript",
        Verb::Scope::Agent, [Verb::Chord.new("n")],
        mnemonic: 'n', group: :edit) { |ctx| ctx.agent_new; nil }

      # ⇧R / ⇧S spelled shift + lowercase: a typed capital normalises to that, and a bare "R"
      # chord could never fire (the registry rejects it at boot).
      r.register Verb::Definition.new(
        "agent.restart", "Restart, resume", "Spawn a fresh child that continues this conversation",
        Verb::Scope::Agent, [Verb::Chord.new("r", shift: true)],
        mnemonic: 'R', group: :edit) { |ctx| ctx.agent_restart; nil }

      r.register Verb::Definition.new(
        "agent.stop", "Stop the agent", "End the child process; the transcript stays",
        Verb::Scope::Agent, [Verb::Chord.new("s", shift: true)],
        available: alive, mnemonic: 'S', group: :danger) { |ctx| ctx.agent_stop; nil }

      # Palette-only and Global on purpose. A Global letter is consulted AFTER every tab's own
      # scope, so it would be shadowed on nine tabs and burn a letter for the rest; `^P →
      # Ask the agent` is the same reach everywhere, and it is rebindable.
      r.register Verb::Definition.new(
        "agent.ask", "Ask the agent", "Send a one-line prompt to the hosted agent without leaving this tab",
        Verb::Scope::Global, category: Verb::Category::System) { |ctx| ctx.agent_ask; nil }
    end
  end
end
