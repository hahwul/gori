require "../spec_helper"

include Gori::Tui

# The picker end of ^F (#1229): the chord, the mode's routing, and the hand-off that opens the
# chosen project on the hit's flow. The overlay itself is project_search_overlay_spec.cr.
#
# `ProjectPicker` and `Runner` both own a live Termisu, and `Runner.new` appears nowhere under
# spec/, so everything past the chord is read off the source with comments stripped — the
# convention issues_primary_flow_spec and agents_chip_spec use for the same reason.

private alias Key = Termisu::Input::Key
private alias Mod = Termisu::Input::Modifier

private def key(k : Key, mods : Mod = Mod::None, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, mods, char)
end

private def code(*parts : String) : String
  File.read(File.join(__DIR__, "..", "..", "src", "gori", *parts))
    .lines.reject(&.lstrip.starts_with?('#')).join('\n')
end

private def method_body(source : String, name : String) : String
  source[/(private )?def #{Regex.escape(name)}\b.*?\n    end/m].not_nil!
end

describe "ProjectPicker.global_search_chord?" do
  it "is ctrl-f and nothing else" do
    ProjectPicker.global_search_chord?(key(Key::LowerF, Mod::Ctrl)).should be_true
    # A bare `f` is a letter of a project name.
    ProjectPicker.global_search_chord?(key(Key::LowerF, Mod::None, 'f')).should be_false
    ProjectPicker.global_search_chord?(key(Key::LowerF, Mod::Ctrl | Mod::Alt)).should be_false
    ProjectPicker.global_search_chord?(key(Key::LowerD, Mod::Ctrl)).should be_false
  end

  it "is what the ⌥ command modifier's F folds onto, like every other picker chord" do
    was = Gori::Settings.command_modifier
    Gori::Settings.command_modifier = "alt"
    begin
      ev = Keybind.dealias(key(Key::LowerF, Mod::Alt, 'f'))
      ProjectPicker.global_search_chord?(ev).should be_true
    ensure
      Gori::Settings.command_modifier = was
    end
  end
end

describe "the picker's :global_search mode" do
  # Every dispatch in the picker ends in an `else` that means "the list": a mode missing from
  # one of them would silently hand its keys, clicks, wheel or IME text to the list underneath.
  it "has its own arm in every dispatch the list would otherwise take" do
    src = code("tui", "project_picker.cr")
    method_body(src, "run").should contain("when :global_search then handle_global_search(ev)")
    method_body(src, "run").should contain("@search.try(&.set_preedit(ev.text))")
    method_body(src, "run").should contain("@search.try(&.tick) if @mode == :global_search")
    method_body(src, "handle_picker_mouse").should contain("when :global_search then handle_global_search_mouse(")
    method_body(src, "picker_wheel").should match(/when :global_search\s+then @search\.try\(&\.wheel\(delta\)\)/)
    method_body(src, "render").should contain("@search.try(&.render(")
    method_body(src, "render_list").should contain("when @mode == :global_search")
  end

  it "cancels the search on every way out, and carries a hit's flow id with its project" do
    src = code("tui", "project_picker.cr")
    finish = method_body(src, "finish_global_search")
    finish.scan(/close_global_search/).size.should eq(3) # :quit, :close, :open
    finish.should contain("@focus_flow_id = outcome.flow_id")
    method_body(src, "close_global_search").should contain("@search.try(&.close)")
  end
end

describe "opening a project on a search hit's flow" do
  it "hands the picker's focus_flow_id to the session's Runner" do
    app = code("app.cr")
    app.should contain("open_or_report_guard(project, term, picker.focus_flow_id)")
    method_body(app, "open_or_report_guard").should contain("open_and_run(project, term, focus_flow_id)")
    method_body(app, "open_and_run").should contain("runner.focus_flow_on_start = focus_flow_id")
  end

  it "opens the History detail after History has loaded, and says so when the flow is gone" do
    runner = code("tui", "runner.cr")
    run = method_body(runner, "run")
    reload_at = run.index!("history_controller.view.reload(@session.store)")
    focus_at = run.index!("open_focus_flow")
    render_at = run.index!("render #")
    (reload_at < focus_at < render_at).should be_true
    focus = method_body(runner, "open_focus_flow")
    focus.should contain("history_controller.view.open_detail_id(id, @session.store)")
    focus.should contain("@overlay = OverlayKind::Detail")
    focus.should contain("@notifications.push(:warn, line)")
  end
end
