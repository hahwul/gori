require "../verb"

module Gori
  module Verbs
    # Sequencer verbs: the cross-tab "Send to Sequencer" entry (space menu in History,
    # History detail, Repeater, and Sitemap) opens a small config popup, then the token
    # collection runs in the BACKGROUND. run/stop/configure act on the focused Sequencer
    # session. The "Send selection to → Sequencer" destination is wired separately
    # (send_menu.cr + the SendPicker commit closure in Runner#send_to_open), so it isn't a
    # verb here.
    def self.register_sequencer(r : Verb::Registry) : Nil
      history_selected = ->(ctx : Verb::ExecContext) { ctx.current_tab == :history && !ctx.selected_flow_id.nil? }
      in_sequencer = ->(ctx : Verb::ExecContext) { ctx.current_tab == :sequencer }
      in_repeater = ->(ctx : Verb::ExecContext) { ctx.current_tab == :repeater }

      r.register Verb::Definition.new(
        "history.sequence", "Send to Sequencer", "Collect this flow's token and analyze its randomness",
        Verb::Scope::Body, available: history_selected, mnemonic: 'q', group: :send) { |ctx| ctx.sequence_selected; nil }
      r.register Verb::Definition.new(
        "detail.sequence", "Send to Sequencer", "Collect this flow's token and analyze its randomness",
        Verb::Scope::HistoryDetail, mnemonic: 'q', group: :send) { |ctx| ctx.close_detail; ctx.sequence_selected; nil }
      r.register Verb::Definition.new(
        "repeater.sequence", "Send to Sequencer", "Collect this request's token repeatedly and analyze randomness",
        Verb::Scope::Repeater, available: in_repeater, mnemonic: 'q') { |ctx| ctx.sequence_from_repeater; nil }
      # Scope::Sitemap already gates this to the Target/Sitemap sub-tab (command_scope
      # returns Sitemap only then) — no current_tab predicate, which would check the
      # retired :sitemap top-level symbol and never fire (Sitemap is now a Target sub-tab).
      r.register Verb::Definition.new(
        "sitemap.sequence", "Send to Sequencer", "Collect the selected endpoint's token and analyze randomness",
        Verb::Scope::Sitemap, mnemonic: 'q', group: :send) { |ctx| ctx.sequence_from_sitemap; nil }

      r.register Verb::Definition.new(
        "sequence.run", "Run collection", "Re-run token collection for this session", Verb::Scope::Sequencer,
        [Verb::Chord.new("r", ctrl: true)], available: in_sequencer, mnemonic: 'r') { |ctx| ctx.sequence_run; nil }
      r.register Verb::Definition.new(
        "sequence.stop", "Stop collection", "Stop the running collection", Verb::Scope::Sequencer,
        [Verb::Chord.new("x", ctrl: true)], available: in_sequencer, mnemonic: 's') { |ctx| ctx.sequence_stop; nil }
      # Reconfigure the token descriptor / goal — the in-body 'c' chord promoted to a verb.
      r.register Verb::Definition.new(
        "sequence.configure", "Configure token", "Set the token location (cookie/header/regex/position/jsonpath) + goal",
        Verb::Scope::Sequencer, [Verb::Chord.new("c")], available: in_sequencer, mnemonic: 'c') { |ctx| ctx.sequence_configure; nil }

      # Getting the verdict OUT. A randomness grade used to live and die inside the session —
      # collected tokens are secrets and are never persisted, so closing the tab took the
      # finding with it. Both are gated on there being a verdict at all, so neither offers
      # itself on a session that has collected nothing.
      has_report = ->(ctx : Verb::ExecContext) { ctx.current_tab == :sequencer && ctx.sequence_report_ready? }
      # ⇧E, matching notes.export / issues.export-key — export is one key across the tree.
      # `Chord.new("E")` would be DEAD: a shifted letter is ("e", shift: true).
      r.register Verb::Definition.new(
        "sequence.export", "Export report…", "Write this session's randomness report to a Markdown file (asks for the path)",
        Verb::Scope::Sequencer, [Verb::Chord.new("e", shift: true)], available: has_report,
        mnemonic: 'E') { |ctx| ctx.sequence_export(:markdown); nil }
      r.register Verb::Definition.new(
        "sequence.export-json", "Export report (JSON)…", "Write this session's randomness report to a JSON file (asks for the path)",
        Verb::Scope::Sequencer, [] of Verb::Chord, available: has_report) { |ctx| ctx.sequence_export(:json); nil }
      r.register Verb::Definition.new(
        "sequence.promote", "File as issue", "Record this randomness verdict in the Issues report (no token values)",
        Verb::Scope::Sequencer, [] of Verb::Chord, available: has_report,
        mnemonic: 'i') { |ctx| ctx.sequence_promote; nil }

      r.register Verb::Definition.new(
        "sequence.find-subtab", "Search sub-tabs", "Filter the open sequencing sessions and jump to one",
        Verb::Scope::Sequencer,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :sequencer && ctx.subtab_search_count >= 2 },
        mnemonic: 'f', section: :tab) { |ctx| ctx.subtab_search_open; nil }
      r.register Verb::Definition.new(
        "sequence.filter-subtabs", "Filter sub-tabs", "Filter the sequencing sub-tab strip by name / host / method",
        Verb::Scope::Sequencer,
        available: ->(ctx : Verb::ExecContext) { ctx.current_tab == :sequencer && ctx.subtab_search_count >= 2 },
        mnemonic: '/', section: :tab) { |ctx| ctx.subtab_filter_open; nil }
    end
  end
end
