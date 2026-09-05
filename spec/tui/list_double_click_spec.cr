require "../support/tui_contract"

include Gori::Tui

# A double-click on a list row does what ↵ does there — and runs the SAME method, so the key,
# the verb and the pointer cannot drift. The shell has detected the pair since the Colormarker
# grew the gesture (`Runner#press_left`); what each list had to add was a `handle_double_click`
# that hit-tests the row with the exact rect its `handle_click` uses and then calls its ↵ body.
# Off every row the answer is false, and the shell delivers the second press as a click.
#
# The ↵ bodies that live on the Runner (they cross tabs) are reached through defaulted `Host`
# seams — `activity_open`, `discover_open_flow`, `diff_to_comparer` — which `FakeHost` counts.

private RECT = TuiContract::AREA

private def project(session, pane : Symbol) : {ProjectController, TuiContract::Host}
  host = TuiContract::Host.new(session)
  ctl = ProjectController.new(host)
  host.tab = :project
  ctl.on_enter
  ctl.view.focus_pane(pane)
  TuiContract.render(ctl)
  {ctl, host}
end

# Invert a view hit-test over the body rect to find a cell on row `idx`.
private def cell_where(&hit : Int32, Int32 -> Bool) : {Int32, Int32}
  RECT.h.times do |y|
    RECT.w.times do |x|
      return {x + 3, y} if hit.call(x, y)
    end
  end
  raise "the row is not on screen"
end

describe "Project tab double-click" do
  it "SCOPE: opens the rule editor for the row, like ↵ / e" do
    TuiContract.with_session("dclick-scope") do |session|
      session.scope.add("include", "host", "a.test").should be_true
      ctl, host = project(session, :scope)
      x, y = cell_where { |x, y| ctl.view.scope_row_at(RECT, x, y) == 0 }
      ctl.handle_click(RECT, x, y)
      ctl.handle_double_click(RECT, x, y).should be_true
      host.scope_rule_edits.should eq([session.scope.rules[0].id])
      ctl.handle_double_click(RECT, 10, RECT.bottom - 1).should be_false
    end
  end

  it "ACTIVITY: opens what the event names, through the Host, like ↵ / o" do
    TuiContract.with_session("dclick-activity") do |session|
      session.store.insert_event("probe", "notice", "info", "something happened", goto_tab: "probe")
      ctl, host = project(session, :activity)
      x, y = cell_where { |x, y| ctl.view.activity_row_at(RECT, x, y) == 0 }
      ctl.handle_click(RECT, x, y)
      ctl.handle_double_click(RECT, x, y).should be_true
      host.activity_opens.should eq(1)
    end
  end

  it "SETTINGS: declines — a single click already activates a row there" do
    TuiContract.with_session("dclick-settings") do |session|
      ctl, _host = project(session, :settings)
      ctl.handle_double_click(RECT, RECT.w // 2, RECT.h // 2).should be_false
    end
  end
end

private def rules_controller(session) : {ProbeController, TuiContract::Host}
  host = TuiContract::Host.new(session)
  ctl = ProbeController.new(host)
  host.tab = :probe
  ctl.jump_subtab(1)
  ctl.on_enter
  TuiContract.render(ctl)
  {ctl, host}
end

private def rule_cell(ctl : ProbeController, idx : Int32) : {Int32, Int32}
  content = BodyChrome.content_rect(RECT, strip: true)
  cell_where { |x, y| ctl.rules.row_at(content, x, y) == idx }
end

describe "Probe RULES double-click" do
  it "opens the editor for a CUSTOM rule and says why not for a built-in" do
    TuiContract.with_session("dclick-rules") do |session|
      session.store.insert_probe_custom_rule("My rule", "d", "response", "body", "regex", "x",
        Gori::Store::Severity::Low)
      ctl, host = rules_controller(session)
      rows = ctl.rules
      custom_idx = nil.as(Int32?)
      builtin_idx = nil.as(Int32?)
      header_idx = nil.as(Int32?)
      rows.move(-1000)
      idx = 0
      loop do
        rows.select_index(idx)
        break if idx > 400
        if rows.selected_index == idx
          row = rows.selected_row.not_nil!
          custom_idx ||= idx if row.custom
          builtin_idx ||= idx if row.custom.nil?
        else
          header_idx ||= idx
        end
        idx += 1
        break if custom_idx && builtin_idx && header_idx
      end
      c, b, h = custom_idx.not_nil!, builtin_idx.not_nil!, header_idx.not_nil!

      # Bring the row into the window first — the render scrolls to the selection, and the
      # hit-test only answers for rows that are drawn.
      rows.select_index(c)
      TuiContract.render(ctl)
      x, y = rule_cell(ctl, c)
      ctl.handle_click(RECT, x, y)
      ctl.handle_double_click(RECT, x, y).should be_true
      host.custom_rule_edits.size.should eq(1)
      host.custom_rule_edits[0].not_nil!.title.should eq("My rule")

      rows.select_index(b)
      TuiContract.render(ctl)
      x, y = rule_cell(ctl, b)
      ctl.handle_click(RECT, x, y)
      ctl.handle_double_click(RECT, x, y).should be_true
      host.custom_rule_edits.size.should eq(1) # no editor for a built-in
      host.statuses.last.should contain("built-in")

      # A section header is not a rule: declined, so the press lands as a plain click. A fresh
      # controller, because the window above scrolled down to the CUSTOM section and the
      # selection can only pull it back to the first RULE — the header above it stays off screen.
      ctl, _host = rules_controller(session)
      x, y = rule_cell(ctl, h)
      ctl.handle_double_click(RECT, x, y).should be_false
    end
  end
end

describe "Intercept queue double-click" do
  it "opens the held message's editor, like ↵ / e" do
    TuiContract.with_session("dclick-intercept") do |session|
      ic = session.interceptor
      ic.toggle
      ic.enqueue_ws("hello".to_slice, to_server: true, method: "GET", target: "/ws", host: "echo.test",
        port: 80, scheme: "http", flow_id: nil, binary: false).should_not be_nil
      host = TuiContract::Host.new(session)
      ctl = InterceptController.new(host)
      host.tab = :intercept
      ctl.on_enter
      TuiContract.render(ctl)
      inner = BodyChrome.frame_inner(RECT)
      x, y = cell_where { |x, y| ctl.view.list_row_at(inner, x, y) == 0 }
      ctl.handle_click(RECT, x, y)
      ctl.view.editing?.should be_false
      ctl.handle_double_click(RECT, x, y).should be_true
      ctl.view.editing?.should be_true
    end
  end
end

describe "Target sub-tabs double-click" do
  it "Discover and Diff decline off every row, through the Target forwarder too" do
    TuiContract.with_session("dclick-target") do |session|
      host = TuiContract::Host.new(session)
      [1, 2].each do |sub|
        ctl = TargetController.new(host)
        host.tab = :target
        ctl.jump_subtab(sub)
        ctl.on_enter
        TuiContract.render(ctl)
        ctl.handle_double_click(RECT, 10, RECT.bottom - 1).should be_false
      end
      host.discover_opens.should eq(0)
      host.diff_comparer_sends.should eq(0)
    end
  end
end
