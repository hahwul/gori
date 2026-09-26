require "../support/tui_contract"

include Gori::Tui

# CONTRACT: `esc` on a tab body always steps OUT of the body.
#
# There are two ways a controller can offer it, and either satisfies this: the pane answers
# the key itself in `handle_body_key` (`@host.request_focus(:subtabs)` / `(:menu)`), or the
# scope it is in binds `escape` to a verb. The one thing that must not happen is neither —
# `Runner#resolve_verb_id` walks Editor → the tab's own scope → Global, and `body.to-menu`
# lives in `Verb::Scope::Body`, which is on NO tab's chain. A tab with its own scope and no
# escape of its own therefore has `esc` resolve to nothing at all, silently: `esc` is a named
# key, so it is not even reported by `Runner.unbound_key_hint`.
#
# That is not hypothetical: the Diff sub-tab shipped that way. Sitemap and Discover, the two
# panes beside it under Target, each register a `*.to-menu`; Diff never did, and because ↑/←
# are its own body keys, ⇧⇥ out to the tab bar was the only way back to the strip.
# Scopes that are NOT a tab body and so are outside this contract.
private NOT_A_BODY = {
  Gori::Verb::Scope::Global,      # fires anywhere; has no focus of its own to leave
  Gori::Verb::Scope::Sidebar,     # the tab bar IS the level esc returns to
  Gori::Verb::Scope::PaletteOpen, # an overlay, dismissed by the overlay seam
  Gori::Verb::Scope::Editor,      # a focus dimension layered over a tab scope, not a tab
}

# Scopes whose controller answers escape in `handle_body_key` instead of binding a verb —
# the other half of the contract, listed because a keymap sweep cannot see it. A scope
# belongs here only with a controller arm to point at.
#
# The default for a NEW scope is "must bind escape", which is the fail-closed side: adding
# a scope without an exit fails here, and the author either registers a `*.to-menu` or adds
# the scope below next to the arm that handles it.
private HANDLED_BY_CONTROLLER = {
  Gori::Verb::Scope::Repeater,        # RepeaterController#handle_body_key → :subtabs
  Gori::Verb::Scope::Fuzzer,          # FuzzerController#handle_escape → :subtabs (+ the empty arm → :menu)
  Gori::Verb::Scope::Miner,           # MinerController#handle_escape → :subtabs / :menu
  Gori::Verb::Scope::Sequencer,       # SequencerController#handle_escape
  Gori::Verb::Scope::OastCallbacks,   # OastController#handle_callbacks_key → :subtabs
  Gori::Verb::Scope::OastProviders,   # OastController#handle_providers_key → :subtabs
  Gori::Verb::Scope::Evidence,        # EvidenceController#handle_body_key
  Gori::Verb::Scope::Intercept,       # InterceptController — esc also clears the queue mark set
  Gori::Verb::Scope::Rewriter,        # RewriterController#handle_body_key
  Gori::Verb::Scope::Colormarker,     # ColormarkerController: colours pane → :rules, rules → :menu
  Gori::Verb::Scope::Comparer,        # ComparerController#handle_body_key → :subtabs
  Gori::Verb::Scope::Decoder,         # DecoderController — esc leaves INSERT first, then the pane
  Gori::Verb::Scope::Jwt,             # JwtController, same shape as Decoder
  Gori::Verb::Scope::Cookie,          # CookieController, same shape as Decoder
  Gori::Verb::Scope::Notes,           # NotesController — esc leaves the editor, then the strip
  Gori::Verb::Scope::ProbeRules,      # ProbeController#handle_body_key, rules arm → :subtabs
  Gori::Verb::Scope::ProjectDesc,     # ProjectController panes: esc is the pane ring's way up
  Gori::Verb::Scope::Project,         #   ″
  Gori::Verb::Scope::HostOverrides,   #   ″
  Gori::Verb::Scope::Env,             #   ″
  Gori::Verb::Scope::ProjectActivity, #   ″
  Gori::Verb::Scope::ProjectSettings, #   ″ (settings → :subtabs)
  Gori::Verb::Scope::Help,            # HelpController#handle_body_key → :menu
  Gori::Verb::Scope::Authorize,       # AuthorizeController#handle_body_key → :menu
}

# And the operator has to be TOLD. The key working is half of it: Authorize, the Colormarker
# rule list, the Comparer, OAST's callbacks and Probe's findings all answered escape and none
# of them said so, while the Fuzzer's empty pane and the Diff sub-tab said `esc` on a line
# where it did nothing. `SetupWizard#footer_hints` already learned this once — every entry
# there ends in "esc" because a clipped single string loses the exit first.
#
# A DESTINATION is required, not the bare word: `esc clear` (drop the filter), `esc read`
# (leave INSERT) and `esc URL` all contain "esc" and none of them leaves the body, so a
# substring test would have passed on panes that name only those.
private EXIT_HINT = /(?:^|[^a-z])esc (?:sub-)?tabs|esc (?:back|rules|list|sub-tabs|tabs)/

# The EFFECTIVE keymap, not `Definition#chords`: a `Settings.keymap_overrides` entry
# replaces a verb's bindings, so reading the definition would report an escape the operator
# has moved away. (What this still cannot see is `available?` — the resolver drops a gated
# verb exactly as it drops an absent one — so a `*.to-menu` must stay ungated.)
private def escape_bound?(keymap : Gori::Verb::Keymap, scope : Gori::Verb::Scope) : Bool
  !keymap.lookup_in(Gori::Verb::Chord.new("escape"), scope).nil?
end

describe "TabController contract — esc leaves the body" do
  # Every scope, not just the one each controller reports in its DEFAULT state: four
  # controllers swap scope with their sub-tab or their open detail (`ProbeController` alone
  # spans Probe/ProbeDetail/ProbeRules), and a roster that builds each pane fresh only ever
  # sees one of them. Sweeping the enum is what makes the secondary panes covered.
  it "every body scope offers escape — bound in the keymap, or answered by its controller" do
    keymap = Gori::Verb::Keymap.build(Gori::Verbs.registry)
    stranded = Gori::Verb::Scope.values.reject do |scope|
      NOT_A_BODY.includes?(scope) || HANDLED_BY_CONTROLLER.includes?(scope) ||
        escape_bound?(keymap, scope)
    end
    stranded.should be_empty
  end

  # The controller half, kept because it is the one that catches a pane which STOPS answering
  # escape without its scope changing — the empty-Fuzzer shape, where the arm existed for a
  # live session and the no-session branch deferred to a keymap that had nothing.
  it "every tab answers escape in its default state" do
    TuiContract.with_session("escape-exit") do |session|
      keymap = Gori::Verb::Keymap.build(session.registry)
      stranded = [] of String
      TuiContract.each_controller(session) do |controller, _host|
        next if controller.handle_body_key(TuiContract.key(Termisu::Input::Key::Escape))
        scope = controller.command_scope
        stranded << "#{controller.class} (#{scope})" unless escape_bound?(keymap, scope)
      end
      stranded.should be_empty
    end
  end

  it "every tab's body hint names the way out" do
    TuiContract.with_session("escape-hint") do |session|
      silent = [] of String
      TuiContract.each_controller(session) do |controller, _host|
        hint = controller.body_hint(:body)
        next if hint.empty? # a pane with no hint at all makes no promise to keep
        silent << "#{controller.class}: #{hint}" unless hint.matches?(EXIT_HINT)
      end
      silent.should be_empty
    end
  end
end
