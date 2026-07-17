require "../verb"

module Gori
  module Verbs
    # Sequencer verbs: the cross-tab "Send to Sequencer" entry (space menu in History,
    # History detail, Repeater, and Sitemap) opens a small config popup, then the token
    # collection runs in the BACKGROUND. run/stop/configure act on the focused Sequencer
    # session. The "Send selection to → Sequencer" destination is wired separately
    # (send_menu.cr + apply_send_to), so it isn't a verb here.
    def self.register_sequencer(r : Verb::Registry) : Nil
      history_selected = ->(ctx : Verb::ExecContext) { ctx.current_tab == :history && !ctx.selected_flow_id.nil? }
      in_sequencer = ->(ctx : Verb::ExecContext) { ctx.current_tab == :sequencer }
      in_repeater = ->(ctx : Verb::ExecContext) { ctx.current_tab == :repeater }

      r.register Verb::Definition.new(
        "history.sequence", "Send to Sequencer", "Collect this flow's token and analyze its randomness",
        Verb::Scope::Body, available: history_selected, mnemonic: 'q') { |ctx| ctx.sequence_selected; nil }
      r.register Verb::Definition.new(
        "detail.sequence", "Send to Sequencer", "Collect this flow's token and analyze its randomness",
        Verb::Scope::HistoryDetail, mnemonic: 'q') { |ctx| ctx.close_detail; ctx.sequence_selected; nil }
      r.register Verb::Definition.new(
        "repeater.sequence", "Send to Sequencer", "Collect this request's token repeatedly and analyze randomness",
        Verb::Scope::Repeater, available: in_repeater, mnemonic: 'q') { |ctx| ctx.sequence_from_repeater; nil }
      # Scope::Sitemap already gates this to the Target/Sitemap sub-tab (command_scope
      # returns Sitemap only then) — no current_tab predicate, which would check the
      # retired :sitemap top-level symbol and never fire (Sitemap is now a Target sub-tab).
      r.register Verb::Definition.new(
        "sitemap.sequence", "Send to Sequencer", "Collect the selected endpoint's token and analyze randomness",
        Verb::Scope::Sitemap, mnemonic: 'q') { |ctx| ctx.sequence_from_sitemap; nil }

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
