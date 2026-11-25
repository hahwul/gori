require "../spec_helper"

# reports/loop #4: one History mark the filter hides (`1 marked ·1 hidden`) silently retargeted
# a bare `^R`, `Space H`, `y` and every other batch verb from the visible cursor row to that
# invisible flow. The card itself is specced on the controllers (history_controller_spec,
# issues_controller_spec); this pins the WIRING, which lives in the Runner — and `Runner.new`
# owns a terminal and appears nowhere under spec/, so it is read off the source with comments
# stripped (the convention issues_primary_flow_spec uses).

private RUNNER_DIR = File.join(__DIR__, "..", "..", "src", "gori", "tui")

private def runner_sources : Array(String)
  [File.join(RUNNER_DIR, "runner.cr")] + Dir.glob(File.join(RUNNER_DIR, "runner", "*.cr")).sort
end

# {method name => body (comment lines dropped)} for every `def` in the Runner's files. A body
# runs from its `def` to the next `def` at any indent — loose, but a call site can only be
# attributed to the method it sits in, which is all this needs.
private def runner_methods : Hash(String, String)
  out = {} of String => String
  runner_sources.each do |path|
    name = nil.as(String?)
    File.each_line(path) do |line|
      next if line.lstrip.starts_with?('#')
      if m = line.match(/^\s*(?:private |protected )?def (?:self\.)?([a-z_]+[?!]?)/)
        name = m[1]
        out[name] = ""
        next
      end
      if n = name
        out[n] += line + "\n"
      end
    end
  end
  out
end

# Every Runner verb that resolves History's marks into an action, and must therefore raise
# the hidden-marks card first. `history_delete` is the controller's own (its card carries the
# irreversibility line) and is specced there.
private HISTORY_GATED = %w[
  repeater_selected fuzz_selected mine_selected probe_active_selected history_discover
  comparer_add_selected authorize_seed_selected scope_add_host issue_create link_attach
  copy_as_open copy_selection tell_agent tell_agent_entry
]

# Methods that read `history_target_flow_ids` but are not verbs of their own: the resolver
# itself, the menu availability gate, and the two helpers only a gated verb above reaches.
private HISTORY_UNGATED_READERS = %w[
  history_target_flow_ids selected_flow_ids copy_as_menu current_link_refs
]

private ISSUES_GATED = %w[issue_set_severity issue_set_status issue_set_cvss]

describe "the hidden-marks gate wiring" do
  it "runs the gate in every batch-capable History verb" do
    methods = runner_methods
    HISTORY_GATED.each do |name|
      body = methods[name]? || fail "no Runner method #{name}"
      body.should contain("history_hidden_marks_gate?")
    end
  end

  # The guard for the NEXT verb: a new reader of History's marks has to either raise the card
  # or be named above with a reason, so the shape cannot quietly come back.
  it "leaves no reader of History's targets ungated" do
    runner_methods.each do |name, body|
      next unless body.includes?("history_target_flow_ids")
      next if HISTORY_GATED.includes?(name) || HISTORY_UNGATED_READERS.includes?(name)
      fail "#{name} reads history_target_flow_ids without history_hidden_marks_gate?"
    end
  end

  it "runs the Issues gate in every batch-capable Issues picker" do
    methods = runner_methods
    ISSUES_GATED.each do |name|
      methods[name].should contain("issues_hidden_marks_gate?")
    end
  end

  # The re-run is pinned to the card's answer: the resolvers read it before anything else, so
  # `c` reaches the verb as the cursor row and `y` as the marks the card was opened over.
  it "pins both resolvers to the card's answer for the re-run" do
    methods = runner_methods
    methods["history_target_flow_ids"].should match(/\A\s*if picked = @history_marks_pick/)
    methods["issues_target_ids"].should match(/\A\s*if picked = @issues_marks_pick/)
  end

  # A card must never come before a certain refusal: answering "all 25" only to be told the
  # batch is capped at 20 (or that the Comparer takes exactly two) is a question with no good
  # answer. The refusals that do not depend on the answer run first.
  it "runs the cap and the Comparer's pair refusal before the card" do
    methods = runner_methods
    {"repeater_selected"     => "batch_within_cap",
     "fuzz_selected"         => "batch_within_cap",
     "mine_selected"         => "batch_within_cap",
     "probe_active_selected" => "batch_within_cap",
     "comparer_add_selected" => "if ids.size > 2"}.each do |name, refusal|
      body = methods[name]
      gate = body.index("history_hidden_marks_gate?").not_nil!
      (body.index(refusal) || fail "#{name}: no #{refusal}").should be < gate
    end
  end

  # `y` over marks copies URLs; the card's cursor-row answer must copy the raw request the
  # bare `y` copies with nothing marked, not the URL of the one row.
  it "copies the cursor row's raw request on the cursor-row answer" do
    runner_methods["copy_selection"].should contain("!history_cursor_pick?")
  end
end
