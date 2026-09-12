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
    {Gori::Verb::Scope::Body, Gori::Verb::Scope::Sitemap, Gori::Verb::Scope::Probe}.each do |scope|
      keymap.lookup(Gori::Verb::Chord.new("s", shift: true), scope).should be_nil
      keymap.lookup(Gori::Verb::Chord.new("s"), scope).should eq("scope.toggle-lens")
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
