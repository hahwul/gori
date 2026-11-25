require "../../support/tui_contract"

include Gori::Tui

# RewriterController under a standing `/` query. The RULES card shows the FILTERED list and
# `@sel` indexes it, so every write that puts a rule in a new row has to find that row in the
# list on screen — or say that the query hides it. Landing on "the last row of the scope
# block" read off the filtered list put the highlight on whatever visible rule closed the
# block: the form closed with no toast, the next `e` edited an unrelated rule, and the new
# one was rewriting traffic off screen.

private def rw_controller(session : Gori::Session) : {RewriterController, TuiContract::Host}
  host = TuiContract::Host.new(session)
  host.tab = :rewriter
  ctl = RewriterController.new(host)
  ctl.on_enter
  {ctl, host}
end

# `/`, the query, ↵ — the keys the operator presses.
private def rw_filter(ctl : RewriterController, query : String) : Nil
  ctl.rewriter_filter
  query.each_char { |c| ctl.handle_list_filter_key(TuiContract.plain(c)) }
  ctl.handle_list_filter_key(TuiContract.key(Termisu::Input::Key::Enter))
end

private def rw_form(name : String, pattern : String, *, edit_id : Int64? = nil) : RewriterRuleOverlay
  RewriterRuleOverlay.new(name: name, pattern: pattern, replacement: "r", edit_id: edit_id,
    edit_scope: edit_id ? Gori::Store::RuleScope::Project : nil)
end

describe RewriterController do
  describe "adding under a `/` filter" do
    it "says the new rule is hidden and keeps the cursor on the rule it was on" do
      TuiContract.with_session("rw-add-hidden") do |session|
        session.rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "crlf-a", "x", name: "crlf one").should be_true
        session.rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "other", "x", name: "unrelated").should be_true
        session.rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "crlf-b", "x", name: "crlf two").should be_true
        ctl, host = rw_controller(session)
        rw_filter(ctl, "crlf")
        TuiContract.render(ctl)
        ctl.selected_rule.not_nil!.name.should eq("crlf one")

        ctl.apply_rewriter_rule(rw_form("hidden-new", "zzzfind")).should be_true
        host.statuses.last.should eq("rule added · hidden by /")
        ctl.selected_rule.not_nil!.name.should eq("crlf one")
        # …and it IS added, armed — the reason the toast has to say so.
        session.rules.rules.find! { |r| r.name == "hidden-new" }.enabled?.should be_true
      end
    end

    it "lands on a new rule the query shows, without a toast" do
      TuiContract.with_session("rw-add-shown") do |session|
        session.rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "crlf-a", "x", name: "crlf one").should be_true
        session.rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "crlf-b", "x", name: "crlf two").should be_true
        ctl, host = rw_controller(session)
        rw_filter(ctl, "crlf")
        TuiContract.render(ctl)

        ctl.apply_rewriter_rule(rw_form("crlf new", "zzzfind")).should be_true
        host.statuses.should be_empty # the row it lands on says so
        ctl.selected_rule.not_nil!.name.should eq("crlf new")
      end
    end
  end

  it "says an edit that stops matching the query hid the rule" do
    TuiContract.with_session("rw-edit-hidden") do |session|
      session.rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "crlf-a", "x", name: "crlf one").should be_true
      session.rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "crlf-b", "x", name: "crlf two").should be_true
      ctl, host = rw_controller(session)
      rw_filter(ctl, "crlf")
      TuiContract.render(ctl)
      one = ctl.selected_rule.not_nil!
      ctl.apply_rewriter_rule(rw_form("renamed", "plain", edit_id: one.id)).should be_true
      host.statuses.last.should eq("rule saved · hidden by /")
      ctl.selected_rule.not_nil!.name.should eq("crlf two")
    end
  end

  it "keeps the cursor on the original when the query hides its duplicate" do
    TuiContract.with_session("rw-dup-hidden") do |session|
      # The copy is named "<name> copy", so a query spanning the name and the pattern hides it.
      session.rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "p", "x", name: "tok-1").should be_true
      session.rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "p", "x", name: "zz-1").should be_true
      ctl, host = rw_controller(session)
      rw_filter(ctl, "-1 p") # "tok-1 p…" and "zz-1 p…", never "tok-1 copy p…"
      TuiContract.render(ctl)
      ctl.selected_rule.not_nil!.name.should eq("tok-1")
      ctl.rewriter_duplicate
      host.statuses.last.should eq("rule copied · hidden by /")
      ctl.selected_rule.not_nil!.name.should eq("tok-1")
    end
  end

  # #9: the card's count is read off ONE list. It used to put the engine's count of every
  # enabled rule over the filtered row count — `2/1 enabled`.
  it "counts the shown rules, with the whole list's size beside them" do
    TuiContract.with_session("rw-count") do |session|
      session.rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "crlf-a", "x", name: "crlf one").should be_true
      session.rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "a", "x", name: "two").should be_true
      session.rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "b", "x", name: "three").should be_true
      ctl, _host = rw_controller(session)
      TuiContract.render(ctl).row(1).should contain("3/3 enabled")
      rw_filter(ctl, "crlf")
      top = TuiContract.render(ctl).row(1)
      top.should contain("1/1 enabled · 3 total")
      top.should_not contain("3/1")
    end
  end
end

# The global library is process-wide: each example gets an empty one in a home of its own.
private def rw_with_globals(&)
  before = Gori::Settings.rewriter_rules
  counter = Gori::Settings.rewriter_next_rule_id
  prev_home = ENV["GORI_HOME"]?
  dir = File.tempname("gori-rw-toast-globals")
  Dir.mkdir_p(dir)
  begin
    ENV["GORI_HOME"] = dir
    Gori::Settings.rewriter_rules = [] of Gori::Settings::RewriterRule
    Gori::Settings.rewriter_next_rule_id = 1_i64
    yield
  ensure
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    Gori::Settings.rewriter_rules = before
    Gori::Settings.rewriter_next_rule_id = counter
    FileUtils.rm_rf(dir)
  end
end

private def rw_clear_filter(ctl : RewriterController) : Nil
  ctl.rewriter_filter
  ctl.handle_list_filter_key(TuiContract.key(Termisu::Input::Key::Escape))
end

# Walk the cursor (as the wheel does) onto the visible rule named `name`.
private def rw_pick(ctl : RewriterController, name : String) : Nil
  ctl.handle_wheel(-1000)
  50.times do
    break if ctl.selected_rule.try(&.name) == name
    ctl.handle_wheel(1)
  end
  ctl.selected_rule.not_nil!.name.should eq(name)
end

# Every toast these writes raise fits the status row whole at 80×24 (59 columns), so the cut
# never takes the half that says where the rule went; the remedy in words goes to the
# Notifications card instead.
describe "RewriterController write toasts" do
  it "fit the 80×24 status row, with and without the hidden-by-filter suffix" do
    rw_with_globals do
      TuiContract.with_session("rw-toast-width") do |session|
        req, head = Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head
        session.rules.add(req, head, "p", "x", name: "anchor-zz", enabled: false).should be_true
        session.rules.add(req, head, "p", "x", name: "ganchor-zz", scope: Gori::Store::RuleScope::Global, enabled: false).should be_true
        ctl, host = rw_controller(session)
        long = Gori::RulePresets::Preset.new("long", "A preset whose name runs well past any status row" * 2, "d",
          Gori::RulePresets.all.max_by(&.rules.size).rules) # several rules: the toast counts the hidden ones

        # On screen: the long forms.
        rw_pick(ctl, "ganchor-zz")
        ctl.rewriter_duplicate
        rw_pick(ctl, "anchor-zz")
        ctl.rewriter_duplicate
        rw_pick(ctl, "anchor-zz copy")
        ctl.rewriter_scope_toggle
        ctl.rewriter_scope_toggle
        ctl.install_preset(long)
        shown = host.statuses.dup
        shown.should contain("global rule duplicated (disabled, like the original)")
        shown.should contain("rule is now GLOBAL — it applies in every project")
        shown.should contain("rule is now project-scoped")
        shown.last.should end_with("\": #{Gori.plural(long.rules.size, "rule")} added")

        # Hidden: "zz p" shows both anchors, never a copy ("anchor-zz copy p") or a new rule.
        rw_filter(ctl, "zz p")
        rw_pick(ctl, "ganchor-zz")
        ctl.rewriter_duplicate
        host.statuses.last.should eq("global rule copied (off) · hidden by /")
        rw_pick(ctl, "anchor-zz")
        ctl.rewriter_duplicate
        host.statuses.last.should eq("rule copied (off) · hidden by /")
        ctl.apply_rewriter_rule(rw_form("q", "q")).should be_true
        host.statuses.last.should eq("rule added · hidden by /")
        ctl.apply_rewriter_rule(RewriterRuleOverlay.new(name: "gq", pattern: "q", replacement: "r", scope: "global")).should be_true
        host.statuses.last.should eq("global rule added · hidden by /")
        ctl.install_preset(long)
        n = long.rules.size
        host.statuses.last.should end_with("\": #{Gori.plural(n, "rule")} added · #{n} hidden by /")
        rw_pick(ctl, "anchor-zz")
        ctl.apply_rewriter_rule(rw_form("renamed", "p", edit_id: ctl.selected_rule.not_nil!.id)).should be_true
        host.statuses.last.should eq("rule saved · hidden by /")

        # A scope move out of the scope the query names.
        rw_clear_filter(ctl)
        rw_filter(ctl, "project")
        rw_pick(ctl, "q")
        ctl.rewriter_scope_toggle
        host.statuses.last.should eq("rule now GLOBAL (all projects) · hidden by /")
        rw_clear_filter(ctl)
        rw_filter(ctl, "global")
        rw_pick(ctl, "gq")
        ctl.rewriter_scope_toggle
        host.statuses.last.should eq("rule now project-scoped · hidden by /")

        host.statuses.each { |toast| Screen.display_width(toast).should be <= RowFilter::TOAST_COLS }
        # …and the long form is in the Notifications card.
        note = host.notifications.all.find! { |entry| entry.message == "Rewriter: rule added, hidden by the filter" }
        note.detail.not_nil!.should contain("“zz p”")
        note.detail.not_nil!.should contain("/ then esc clears the filter")
      end
    end
  end
end
