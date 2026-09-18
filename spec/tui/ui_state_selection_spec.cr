require "../spec_helper"

# Source-pinned gates for the selection channel (#1091).
#
# `Runner.new` owns a terminal and appears nowhere under `spec/`, and the publish itself only
# exists on the event-loop tick — so the properties below cannot be reached by constructing
# anything. They are pinned the way `peer_edit_sync_spec.cr` pins the ui-state write gate:
# by reading the source with comment lines stripped.
private RUNNER_SRC  = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner.cr"))
private RUNNER_CODE = RUNNER_SRC.lines.reject(&.lstrip.starts_with?('#')).join('\n')

describe "the ui-state identity" do
  it "includes the active tab's SELECTION, or no mark gesture ever publishes" do
    # THE regression this whole feature turns on. The tuple is compared on every tick and the
    # row is only rewritten when it moved; `t`, `⇧T`, mark-clear and `⇧arrow` leave
    # active_tab, focus, selected_flow_id and subtab exactly where they were. Drop this
    # component and every controller example in `mcp_selection_spec.cr` still passes while
    # the operator's marks reach no agent at all — which is the bug, not a symptom of it.
    alias_line = RUNNER_CODE.lines.find(&.includes?("alias UiIdentity"))
    alias_line.should_not be_nil
    alias_line.not_nil!.should contain("SelectionIdent")

    body = RUNNER_CODE[/def ui_state_identity.*?\n {4}end\n/m]
    body.should_not be_nil
    body.not_nil!.should contain("current_selection_ident")
  end

  it "folds marks from EVERY tab, not just the active one" do
    # `marks_elsewhere` is the answer to "I marked four in History, then walked to Repeater
    # and said 'use my selection'". It only refreshes if a mark on an inactive tab moves the
    # identity, so the roll-up count belongs in the tuple beside the active tab's ident.
    body = RUNNER_CODE[/def ui_state_identity.*?\n {4}end\n/m].not_nil!
    body.should contain("total_mark_count")
    RUNNER_CODE.should contain("def write_marks_elsewhere")
  end

  it "moves when a drill-in opens, on BOTH tabs that have one" do
    # Opening a detail changes no tab, no focus, no cursor (it opens ON the cursor row) and no
    # mark — so without a component for it the row went on saying `target_source:"marks"` for
    # the whole time the operator was reading one row, while every key on screen had collapsed
    # to that one. History was found end-to-end (the publish only exists on the tick); Issues
    # has the identical shape and is pinned here so it cannot regress separately.
    hist = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "controllers", "history_controller.cr"))
    hist[/def list_selection_ident.*?\n {4}end\n/m].not_nil!.should contain("detail_pinned_flow_id")
    iss = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "controllers", "issues_controller.cr"))
    iss[/def list_selection_ident.*?\n {4}end\n/m].not_nil!.should contain("detail_issue")
  end

  it "does not carry the live filter text, which would make typing a write loop" do
    # Every keystroke in a `/` bar would otherwise fire the gate once per throttle window —
    # ~3 `settings` commits a second, each bumping `data_version` and making every watching
    # TUI reload rules, scope and bindings. `rows` covers the same ground at the moment the
    # debounced search actually lands.
    %w[history issues sitemap intercept].each do |tab|
      src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "controllers", "#{tab}_controller.cr"))
      body = src[/def list_selection_ident.*?\n {4}end\n/m]
      body.should_not be_nil
      body.not_nil!.should_not contain("query:")
    end
  end
end

describe "the ui-state payload" do
  it "asks the tab whether it has a selection before opening the key" do
    # A Help or Settings tab must write no `selection` key at all rather than an empty object
    # into a row that is rewritten every throttle window.
    body = RUNNER_CODE[/private def ui_state_json.*?\n {4}end\n/m]
    body.should_not be_nil
    body.not_nil!.should contain("mcp_selection?")
    body.not_nil!.should contain("write_mcp_selection")
  end
end

describe "this window's presence marker" do
  it "is announced in `run` and released in its teardown, not left to the process" do
    # Scoped to the project VISIT, not the process: leaving for the picker keeps gori alive,
    # and an agent must not be told a window is open for a project nobody is looking at.
    RUNNER_CODE.should contain("announce_tui_presence")
    lines = RUNNER_CODE.lines
    stop = lines.index(&.includes?("@statusline.stop"))
    stop.should_not be_nil
    # The same teardown block the statusline worker is wound down in — that block is the
    # `ensure` that runs on quit, on leave_project and on the raise paths alike.
    lines[stop.not_nil!, 6].any?(&.includes?("release_tui_presence")).should be_true
  end

  it "is owned by the Runner, never by Session" do
    # `Session.open` also backs headless `gori run capture`, which draws nothing — announcing
    # there would tell an agent a TUI window is up when there is no window.
    session_src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "session.cr"))
    session_src.should_not contain("KIND_TUI")
    session_src.should_not contain("announce_tui_presence")
  end
end

describe "the base-owned selection hooks" do
  it "are not shadowed by any controller" do
    # Crystal has no `override`: a subclass defining `selection_ident` or `write_mcp_selection`
    # silently REPLACES the base's version and drops the sub-tab marks (or the whole body),
    # with no error anywhere. The three hooks meant for overriding are `selection_kind`,
    # `write_selection_fields` and `list_selection_ident`.
    root = File.join(__DIR__, "..", "..", "src", "gori", "tui")
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).each do |path|
      next if File.basename(path) == "tab_controller.cr"
      File.read(path).lines.each_with_index do |line, i|
        code = line.lstrip
        next if code.starts_with?('#')
        if code.starts_with?("def selection_ident") || code.starts_with?("def write_mcp_selection") ||
           code.starts_with?("def mcp_selection?") || code.starts_with?("def write_subtab_marks")
          offenders << "#{path}:#{i + 1}"
        end
      end
    end
    offenders.should be_empty
  end
end
