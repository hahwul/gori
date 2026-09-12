require "../support/tui_contract"
require "../support/fake_context"

include Gori::Tui

# One key, one meaning across the tabs a hand moves between. Each example here pins a chord
# that used to mean something ELSE on one tab than on every sibling, and now does not.
describe "one key, one meaning" do
  keymap = Gori::Verb::Keymap.build(Gori::Verbs.registry)

  it "`d` never starts a crawl — Sitemap's discover is a menu row like its siblings' sends" do
    keymap.lookup(Gori::Verb::Chord.new("d"), Gori::Verb::Scope::Sitemap).should be_nil
    Gori::Verbs.registry["sitemap.discover"].chords.should be_empty
    Gori::Verbs.registry["sitemap.discover"].menu_key.should eq('d')
  end

  it "`⇧X` is the wipe chord and nothing quieter — the rule-default toggles are menu rows" do
    keymap.lookup(Gori::Verb::Chord.new("x", shift: true), Gori::Verb::Scope::Rewriter).should be_nil
    keymap.lookup(Gori::Verb::Chord.new("x", shift: true), Gori::Verb::Scope::Colormarker).should be_nil
    keymap.lookup(Gori::Verb::Chord.new("x", shift: true), Gori::Verb::Scope::Body).should eq("history.clear")
  end

  it "`[` / `]` are the Global tab cycle inside an issue too" do
    keymap.lookup(Gori::Verb::Chord.new("]"), Gori::Verb::Scope::IssuesDetail).should eq("nav.next-tab")
    keymap.lookup(Gori::Verb::Chord.new("["), Gori::Verb::Scope::IssuesDetail).should eq("nav.prev-tab")
    Gori::Verbs.registry["issue.severity-up"].chords.should be_empty
    Gori::Verbs.registry["issue.severity-up"].hidden?.should be_false # a menu row now, so it must show
  end

  it "`o` opens the row's flow on History, as on every other list" do
    keymap.lookup(Gori::Verb::Chord.new("o"), Gori::Verb::Scope::Body).should eq("body.open")
  end

  it "the scope lens has one key — the Global `s` — and no ⇧S twin" do
    {Gori::Verb::Scope::Body, Gori::Verb::Scope::Sitemap}.each do |scope|
      keymap.lookup(Gori::Verb::Chord.new("s", shift: true), scope).should be_nil
      keymap.lookup(Gori::Verb::Chord.new("s"), scope).should eq("scope.toggle-lens")
    end
    # Probe is the ONE tab that shadows it, and deliberately: `s` = go to source is the
    # meaning #1051 settled and F2 grew, and the lens is `probe.scope-toggle` in the menu
    # there — reachable where its effect is visible, which is the trade that scope spells out.
    keymap.lookup(Gori::Verb::Chord.new("s", shift: true), Gori::Verb::Scope::Probe).should be_nil
    keymap.lookup(Gori::Verb::Chord.new("s"), Gori::Verb::Scope::Probe).should eq("probe.open-evidence")
    Gori::Verbs.registry["probe.scope-toggle"].menu_key.should eq('s')
  end

  # `s` means GO TO SOURCE — the Evidence tab's grammar, which #1051 gave the Issues detail's
  # RELATED card and F2 gives Probe. `o` is left as the `↵` alias it is in the four scopes
  # where it opens the row's OWN detail, and is bound nowhere else.
  it "`s` goes to the tab the row lives in, and `o` is only ever ↵'s alias" do
    {Gori::Verb::Scope::Evidence     => "evidence.source",
     Gori::Verb::Scope::IssuesDetail => "issue.goto-link",
     Gori::Verb::Scope::Probe        => "probe.open-evidence",
     Gori::Verb::Scope::ProbeDetail  => "probe.open-flow",
    }.each do |scope, id|
      keymap.lookup(Gori::Verb::Chord.new("s"), scope).should eq(id), scope.to_s
    end
    {Gori::Verb::Scope::Body            => "body.open",
     Gori::Verb::Scope::Discover        => "discover.open-flow",
     Gori::Verb::Scope::Sitemap         => "sitemap.open-flow",
     Gori::Verb::Scope::ProjectActivity => "activity.open",
    }.each do |scope, id|
      keymap.lookup(Gori::Verb::Chord.new("o"), scope).should eq(id), scope.to_s
    end
    # …and in three of the four it is literally `↵`'s alias. The Sitemap is the standing
    # exception the audit names: `↵`/`→` EXPAND a tree node there, so `o` is the only key
    # that opens the row's own flow rather than a second spelling of one.
    {"body.open", "discover.open-flow", "activity.open"}.each do |id|
      Gori::Verbs.registry[id].chords.map(&.key).should contain("enter"), id
    end
    Gori::Verbs.registry["sitemap.open-flow"].chords.map(&.key).should_not contain("enter")
    # Every other scope: `o` is unbound.
    Gori::Verb::Scope.each do |scope|
      next if {Gori::Verb::Scope::Body, Gori::Verb::Scope::Discover, Gori::Verb::Scope::Sitemap,
               Gori::Verb::Scope::ProjectActivity}.includes?(scope)
      keymap.lookup(Gori::Verb::Chord.new("o"), scope).should be_nil, scope.to_s
    end
  end

  # `y` is the app's copy letter: 24 scopes bound it and four did not — Intercept answered only
  # `^Y`, the Evidence archive and the Project ACTIVITY feed answered nothing at all, and the
  # OAST callback detail copied from a raw controller arm the keymap could not see. All four
  # are real chords now, so the reflex lands and the Hotkeys editor can move every one of them.
  it "`y` copies on every list that has something to copy" do
    {Gori::Verb::Scope::Intercept       => "intercept.copy",
     Gori::Verb::Scope::Evidence        => "evidence.copy",
     Gori::Verb::Scope::ProjectActivity => "activity.copy",
     Gori::Verb::Scope::OastCallbacks   => "oast.copy-callback",
    }.each do |scope, id|
      keymap.lookup(Gori::Verb::Chord.new("y"), scope).should eq(id), scope.to_s
    end
    # `^Y` stays pinned beside the letter wherever a pane can be typed into.
    keymap.lookup(Gori::Verb::Chord.new("y", ctrl: true), Gori::Verb::Scope::Intercept)
      .should eq("intercept.copy")
  end

  # `x` = select line was a registered chord in both scopes AND a raw controller arm doing
  # the same thing first, so the verb showed in the Hotkeys editor and a rebind moved
  # nothing. The arms are gone; these are the bindings the letter actually reaches.
  it "`x` selects the line through the keymap, not through a controller arm" do
    keymap.lookup(Gori::Verb::Chord.new("x"), Gori::Verb::Scope::Repeater)
      .should eq("repeater.select-line")
    keymap.lookup(Gori::Verb::Chord.new("x"), Gori::Verb::Scope::IssuesDetail)
      .should eq("issue.select-line")
    # The Sequencer's `c` was the third of the same shape — one arm, one identical verb.
    keymap.lookup(Gori::Verb::Chord.new("c"), Gori::Verb::Scope::Sequencer)
      .should eq("sequence.configure")
  end

  # `/` filters the list in eleven scopes and did not exist in the rule lists at all — the
  # Probe RULES sub-tab is ~40 built-ins across three sections, where reaching one meant
  # scrolling past the other two. All three share `RowFilter`, and all three are a LENS: a
  # hidden rule is still enabled.
  it "`/` filters the rule lists the way it filters every other list" do
    {Gori::Verb::Scope::Colormarker => "colormarker.filter",
     Gori::Verb::Scope::Rewriter    => "rewriter.filter",
     Gori::Verb::Scope::ProbeRules  => "probe-rules.filter",
    }.each do |scope, id|
      keymap.lookup(Gori::Verb::Chord.new("/"), scope).should eq(id), scope.to_s
      Gori::Verbs.registry[id].menu_key.should eq('f'), id
    end
  end

  # `t` / `⇧T` are mark / mark-all in History, Issues and the Intercept queue. The Sitemap had
  # the first and not the second.
  it "`⇧T` marks all on the Sitemap, as it does in every other marked list" do
    {Gori::Verb::Scope::Body      => "history.mark-all",
     Gori::Verb::Scope::Issues    => "issues.mark-all",
     Gori::Verb::Scope::Intercept => "intercept.mark-all",
     Gori::Verb::Scope::Sitemap   => "sitemap.mark-all",
    }.each do |scope, id|
      keymap.lookup(Gori::Verb::Chord.new("t", shift: true), scope).should eq(id), scope.to_s
    end
  end

  # `x` = select this line in fourteen scopes and "enable/disable this rule" in four. The
  # majority wins (it is also the INS-adjacent gesture), and the rule toggles take `t` —
  # "flip this row's flag", which is what `t` means as MARK in History, Issues, the Sitemap
  # and the Intercept queue. A rule list has no marks, so nothing collides.
  it "`x` selects a line and `t` flips a row's flag, in every scope that binds either" do
    {Gori::Verb::Scope::Colormarker   => "colormarker.toggle",
     Gori::Verb::Scope::OastProviders => "oast.toggle-provider",
     Gori::Verb::Scope::ProbeRules    => "probe-rules.toggle",
     Gori::Verb::Scope::Rewriter      => "rewriter.toggle",
    }.each do |scope, id|
      keymap.lookup(Gori::Verb::Chord.new("t"), scope).should eq(id), scope.to_s
    end
    # `t` is mark in the four list scopes that have marks — one letter, one question.
    {Gori::Verb::Scope::Body      => "history.mark-toggle",
     Gori::Verb::Scope::Issues    => "issues.mark-toggle",
     Gori::Verb::Scope::Sitemap   => "sitemap.mark-toggle",
     Gori::Verb::Scope::Intercept => "intercept.mark-toggle",
    }.each do |scope, id|
      keymap.lookup(Gori::Verb::Chord.new("t"), scope).should eq(id), scope.to_s
    end
    # …and no scope binds `x` to anything but select-line now.
    Gori::Verb::Scope.each do |scope|
      next unless id = keymap.lookup(Gori::Verb::Chord.new("x"), scope)
      id.should end_with("select-line"), "#{scope}: x = #{id}"
    end
  end

  # `r` was "send this to the Repeater" in five scopes, Run on the Diff, Resume on OAST and
  # Refresh on the Project feed. The majority has a real loop behind it and wins; `^R` already
  # owns Run in nine scopes, so the Diff's Run joins them and the other two give the letter up.
  it "`r` sends to the Repeater, and `^R` runs" do
    {Gori::Verb::Scope::Body        => "history.repeater",
     Gori::Verb::Scope::Evidence    => "evidence.repeater",
     Gori::Verb::Scope::Probe       => "probe.repeater-evidence",
     Gori::Verb::Scope::ProbeDetail => "probe.repeater-flow",
     Gori::Verb::Scope::Sitemap     => "sitemap.repeater",
    }.each do |scope, id|
      # History's is `^R` by an older decision that outranks this one (hotkeys.md names it);
      # the rest are the bare letter.
      expected = scope == Gori::Verb::Scope::Body ? nil : id
      keymap.lookup(Gori::Verb::Chord.new("r"), scope).should eq(expected), scope.to_s
    end
    ctrl_r = Gori::Verb::Chord.new("r", ctrl: true)
    keymap.lookup(ctrl_r, Gori::Verb::Scope::Diff).should eq("diff.run")
    keymap.lookup(ctrl_r, Gori::Verb::Scope::Body).should eq("history.repeater")
    # The two that gave it up.
    keymap.lookup(Gori::Verb::Chord.new("r"), Gori::Verb::Scope::OastCallbacks).should be_nil
    keymap.lookup(Gori::Verb::Chord.new("r", shift: true), Gori::Verb::Scope::OastCallbacks)
      .should eq("oast.sessions")
    keymap.lookup(Gori::Verb::Chord.new("r"), Gori::Verb::Scope::ProjectActivity).should be_nil
    Gori::Verbs.registry["activity.refresh"].chords.should be_empty
  end

  it "History's hidden nav verbs are gated to History, not to every Body-scope tab" do
    ctx = FakeExecContext.new
    ctx.current_tab = :help
    Gori::Verbs.registry["body.up"].available?(ctx).should be_false
    Gori::Verbs.registry["body.down"].available?(ctx).should be_false
    ctx.current_tab = :history
    Gori::Verbs.registry["body.down"].available?(ctx).should be_true
  end
end

describe "TabController#insert_key_refusal" do
  it "names the read-only pane beside an editor, and stays quiet on the editor itself" do
    TuiContract.with_session("insert-refusal") do |session|
      TuiContract.each_controller(session) do |controller, _host|
        case controller
        when FuzzerController
          controller.fuzz_new
          v = controller.current_view.not_nil!
          v.focus_pane(:template)
          controller.insert_key_refusal.should be_nil
          v.focus_pane(:results)
          controller.insert_key_refusal.not_nil!.should contain("read-only")
        when DecoderController
          controller.focus_first
          controller.insert_key_refusal.should be_nil
          controller.focus_last # OUTPUT
          controller.insert_key_refusal.not_nil!.should contain("read-only")
        when IssuesController
          # The LIST has no editor beside it, so Global `i` (toggle intercept) must still
          # reach the keymap from here.
          controller.insert_key_refusal.should be_nil
        else
          controller.insert_key_refusal # never raises on a tab without such a pane
        end
      end
    end
  end

  # The other half of the keymap-ownership example above: a chord the registry owns is only
  # live if the controller HANDS THE KEY BACK. All three of these bodies swallow whatever
  # they do not name, so each had to decline its letter explicitly when its arm came out.
  it "hands `x` and `c` back to the keymap instead of swallowing them" do
    TuiContract.with_session("select-line-fallthrough") do |session|
      store = session.store
      store.insert_issue("reflected param", Gori::Store::Severity::Medium, "acme.test", nil)
      TuiContract.each_controller(session) do |controller, _host|
        case controller
        when RepeaterController
          controller.repeater_new
          v = controller.current_view.not_nil!
          {:request, :target, :response}.each do |pane|
            v.focus_pane(pane)
            controller.repeater_read_mode?.should be_true, pane.to_s
            controller.handle_body_key(TuiContract.plain('x')).should be_false, pane.to_s
          end
        when IssuesController
          controller.view.reload(store)
          controller.view.open_detail(store).should be_true
          controller.view.focus_notes!
          controller.issues_notes_read_mode?.should be_true
          controller.handle_detail_key(TuiContract.plain('x')).should be_false
          # The Sequencer's `c` is the third of the shape and its decline is named in
          # `handle_body_key`; standing a session up here would mean starting a real
          # collection, so the keymap example above is what pins that one.
        end
      end
    end
  end

  # IssuesDetail claimed bare `i` from ANY detail focus and dropped into the notes editor, so
  # the Global intercept toggle vanished on this tab with nothing said — the one silent member
  # of a family that was taught to speak five tabs ago. RELATED is a read-only pane beside an
  # editor; it answers like one now.
  it "refuses `i` from RELATED and stays quiet once NOTES has focus" do
    TuiContract.with_session("issues-related-i") do |session|
      store = session.store
      store.insert_issue("reflected param", Gori::Store::Severity::Medium, "acme.test", nil)
      TuiContract.each_controller(session) do |controller, _host|
        next unless controller.is_a?(IssuesController)
        controller.view.reload(store)
        controller.view.open_detail(store).should be_true
        controller.view.notes_focused?.should be_false
        refusal = controller.insert_key_refusal.not_nil!
        refusal.should contain("read-only")
        refusal.should contain("intercept")
        # …and the detail handler must HAND the key back, or the runner never reaches the
        # refusal it just produced.
        controller.handle_detail_key(TuiContract.plain('i')).should be_false

        controller.view.focus_notes!
        controller.insert_key_refusal.should be_nil
      end
    end
  end
end

describe "Rewriter sections on the focus ring" do
  it "walks rules → extract → bindings on ⇥ and leaves for the tab bar off either end" do
    TuiContract.with_session("rewriter-ring") do |session|
      TuiContract.each_controller(session) do |controller, _host|
        next unless controller.is_a?(RewriterController)
        controller.pane_advance(-1).should be_false # already on the first section
        controller.pane_advance(1).should be_true
        controller.pane_advance(1).should be_true
        controller.pane_advance(1).should be_false # off the last section
        # The bracket keys are the Global tab chords again, not a section cycle.
        ev = Termisu::Event::Key.new(Termisu::Input::Key::RightBracket, Termisu::Input::Modifier::None, ']')
        controller.handle_body_key(ev).should be_false
      end
    end
  end
end
