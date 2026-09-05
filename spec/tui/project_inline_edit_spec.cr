require "../support/tui_contract"

include Gori::Tui

# The Project tab's HOST OVERRIDES and ENV panes edit a row IN PLACE: `↵` / `e` / a double-click
# turn the selected row into the editor, where it sits, and the list around it holds still. The
# editor used to be a one-line form on the FIRST interior line of the card — every entry moved
# down a row to make room, the row being edited lost its highlight, and the input was a
# hand-rolled `@input`/`@icx` pair that answered ←/→/⌫ and nothing else. It is a `TextField`
# now, drawn on the row, and the pointer reaches it: a press places the caret, a pair selects a
# word, and a press on ANOTHER row saves first (the blur-is-save rule the SETTINGS pane already
# had) — a refused save keeps the editor up with its reason and drops the pick.
#
# The ADD row is unchanged: it still takes the first line, because there is no row of its own
# to sit on yet.

private RECT = TuiContract::AREA
private alias KEY = Termisu::Input::Key

private def with_overrides(&)
  TuiContract.with_session("inline-edit") do |session|
    session.host_overrides.add("a.test", "10.0.0.1").should be_true
    session.host_overrides.add("b.test", "10.0.0.2").should be_true
    host = TuiContract::Host.new(session)
    ctl = ProjectController.new(host)
    host.tab = :project
    ctl.on_enter
    ctl.view.focus_pane(:overrides)
    TuiContract.render(ctl)
    yield ctl, host, session
  end
end

# The screen row `needle` is drawn on, read from a fresh render — so the assertions are about
# what the operator sees, not about an offset that would drift with the card geometry.
private def row_of(ctl : ProjectController, needle : String) : Int32
  b = TuiContract.render(ctl)
  (0...RECT.h).find { |r| b.row(r).includes?(needle) } || raise "#{needle.inspect} was not drawn"
end

# A cell on override row `idx`, found by inverting the view's own hit-test over the body rect
# the shell hands `handle_click` — so the spec cannot disagree with `ov_row_at`. `x_off` steps
# right of the marker column into the text.
private def ov_cell(ctl : ProjectController, idx : Int32, x_off : Int32 = 3) : {Int32, Int32}
  RECT.h.times do |y|
    RECT.w.times do |x|
      return {x + x_off, y} if ctl.view.ov_row_at(RECT, x, y) == idx
    end
  end
  raise "override row #{idx} is not on screen"
end

private def env_cell(ctl : ProjectController, idx : Int32, x_off : Int32 = 3) : {Int32, Int32}
  RECT.h.times do |y|
    RECT.w.times do |x|
      return {x + x_off, y} if ctl.view.env_row_at(RECT, x, y) == idx
    end
  end
  raise "env row #{idx} is not on screen"
end

# Opens the editor on row `idx` with the pair, then DRAWS — the shell always paints between
# events, and the field's pointer geometry is whatever it was last drawn at.
private def open_edit(ctl : ProjectController, idx : Int32) : {Int32, Int32}
  x, y = ov_cell(ctl, idx)
  ctl.handle_click(RECT, x, y)
  ctl.handle_double_click(RECT, x, y).should be_true
  ctl.view.ov_editing?.should be_true
  TuiContract.render(ctl)
  {x, y}
end

private def press(ctl : ProjectController, k : Termisu::Input::Key, mods : Termisu::Input::Modifier = :none) : Nil
  ctl.handle_body_key(TuiContract.key(k, mods))
end

private def type(ctl : ProjectController, text : String) : Nil
  text.each_char { |c| ctl.handle_body_key(TuiContract.plain(c)) }
end

private def backspace(ctl : ProjectController, n : Int32) : Nil
  n.times { press(ctl, KEY::Backspace) }
end

describe "Project HOST OVERRIDES inline edit" do
  it "a double-click turns the entry's own row into the editor, and the list holds still" do
    with_overrides do |ctl, _host, _session|
      a_row = row_of(ctl, "a.test")
      b_row = row_of(ctl, "b.test")
      open_edit(ctl, 0)
      ctl.view.ov_input_text.should eq("10.0.0.1 a.test")
      # The field draws the line as one string where the IP / → / host columns were.
      row_of(ctl, "10.0.0.1 a.test").should eq(a_row)
      row_of(ctl, "b.test").should eq(b_row) # not pushed down a row
    end
  end

  it "↵ opens the same in-place editor the pair does" do
    with_overrides do |ctl, _host, _session|
      a_row = row_of(ctl, "a.test")
      press(ctl, KEY::Enter)
      ctl.view.ov_editing?.should be_true
      row_of(ctl, "10.0.0.1 a.test").should eq(a_row)
    end
  end

  it "the ADD row still takes the first line and pushes the list down" do
    with_overrides do |ctl, _host, _session|
      a_row = row_of(ctl, "a.test")
      ctl.hostov_add_entry
      ctl.view.ov_adding?.should be_true
      ctl.view.ov_editing?.should be_false
      row_of(ctl, "add ").should eq(a_row)
      row_of(ctl, "a.test").should eq(a_row + 1)
    end
  end

  it "a press on another row SAVES the edit, then picks that row" do
    with_overrides do |ctl, host, session|
      open_edit(ctl, 0)
      backspace(ctl, "a.test".size)
      type(ctl, "c.test")
      ctl.view.ov_input_text.should eq("10.0.0.1 c.test")
      TuiContract.render(ctl)
      x, y = ov_cell(ctl, 1)
      ctl.handle_click(RECT, x, y).should be_true
      ctl.view.ov_adding?.should be_false
      host.statuses.last.should contain("updated")
      hosts = session.host_overrides.entries.map(&.host)
      hosts.should contain("c.test")
      hosts.should_not contain("a.test")
      ctl.view.selected_override_host.should eq(session.host_overrides.entries[1].host)
    end
  end

  it "a refused save keeps the editor up with its reason and drops the pick" do
    with_overrides do |ctl, host, session|
      open_edit(ctl, 0)
      backspace(ctl, "10.0.0.1 a.test".size)
      type(ctl, "10.0.0.1") # an address with no host — `parse_line` refuses it
      TuiContract.render(ctl)
      x, y = ov_cell(ctl, 1)
      ctl.handle_click(RECT, x, y).should be_true
      ctl.view.ov_editing?.should be_true
      ctl.view.ov_input_text.should eq("10.0.0.1")
      host.statuses.last.should contain("need")
      session.host_overrides.entries.map(&.host).should eq(["a.test", "b.test"])
    end
  end

  it "an emptied row is cancelled by the pick, not saved" do
    with_overrides do |ctl, _host, session|
      open_edit(ctl, 0)
      backspace(ctl, "10.0.0.1 a.test".size)
      ctl.view.ov_input_text.should eq("")
      TuiContract.render(ctl)
      x, y = ov_cell(ctl, 1)
      ctl.handle_click(RECT, x, y).should be_true
      ctl.view.ov_adding?.should be_false
      session.host_overrides.entries.map(&.host).should eq(["a.test", "b.test"])
      ctl.view.selected_override_host.should eq("b.test")
    end
  end

  it "a press inside the open field is a caret, and a pair there selects a word" do
    with_overrides do |ctl, _host, _session|
      x, y = open_edit(ctl, 0)
      ctl.handle_click(RECT, x + 2, y).should be_true
      ctl.view.ov_editing?.should be_true
      ctl.view.selected_override_host.should eq("a.test")
      ctl.handle_double_click(RECT, x + 2, y).should be_true
      ctl.view.ov_editing?.should be_true
    end
  end

  it "declines a pair off every row, so the shell delivers it as a click" do
    with_overrides do |ctl, _host, _session|
      ctl.handle_double_click(RECT, 10, RECT.bottom - 1).should be_false
    end
  end

  it "↹ types the separator, and the field's own keys reach it" do
    with_overrides do |ctl, _host, _session|
      open_edit(ctl, 0)
      press(ctl, KEY::Tab)
      ctl.view.ov_input_text.should eq("10.0.0.1 a.test ")
      press(ctl, KEY::Home)
      type(ctl, "x")
      ctl.view.ov_input_text.should eq("x10.0.0.1 a.test ")
      press(ctl, KEY::End)
      press(ctl, KEY::Backspace, :alt) # ⌥⌫ — one run back: the trailing separator
      ctl.view.ov_input_text.should eq("x10.0.0.1 a.test")
      ctl.view.ov_editing?.should be_true # still the same row's editor
    end
  end
end

# `Settings.project_env_vars` is a process-wide singleton the whole suite shares — snapshot it
# and always put it back.
private def with_project_vars(vars : Array({String, String}), &)
  saved = Gori::Settings.project_env_vars
  saved_prefix = Gori::Settings.env_prefix
  Gori::Settings.project_env_vars = vars
  Gori::Settings.env_prefix = "$"
  begin
    yield
  ensure
    Gori::Settings.project_env_vars = saved
    Gori::Settings.env_prefix = saved_prefix
  end
end

describe "Project ENV inline edit" do
  it "a double-click turns the var's own row into the editor; the ADD row stays on top" do
    TuiContract.with_session("inline-env") do |session|
      # AFTER the session opens: `Session.open` seeds the project vars from the store.
      with_project_vars([{"ALPHA", "1"}, {"BETA", "2"}]) do
        host = TuiContract::Host.new(session)
        ctl = ProjectController.new(host)
        host.tab = :project
        ctl.on_enter
        ctl.view.focus_pane(:env)
        TuiContract.render(ctl)
        alpha_row = row_of(ctl, "ALPHA")
        beta_row = row_of(ctl, "BETA")

        x, y = env_cell(ctl, 1)
        ctl.handle_click(RECT, x, y)
        ctl.handle_double_click(RECT, x, y).should be_true
        ctl.view.env_editing?.should be_true
        ctl.view.env_input_text.should eq("BETA 2")
        TuiContract.render(ctl)
        row_of(ctl, "BETA 2").should eq(beta_row)
        row_of(ctl, "ALPHA").should eq(alpha_row)

        press(ctl, KEY::Escape)
        ctl.view.env_adding?.should be_false
        ctl.env_add_var
        row_of(ctl, "add ").should eq(alpha_row)
        row_of(ctl, "ALPHA").should eq(alpha_row + 1)
      end
    end
  end
end
