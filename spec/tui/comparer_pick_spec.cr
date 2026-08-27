require "../spec_helper"

# `a` / `b` on the Comparer tab draw their rows THROUGH the active Scope lens, the way History
# and the Sitemap already do. Runner owns a live terminal and is constructed nowhere under spec/,
# so this open-site is pinned in source like `spec/tui/subtab_find_key_spec.cr`. The two halves a
# source scan cannot reach are covered where they live: the lens SQL in `spec/scope_spec.cr`, the
# "no flows in scope" card in `spec/tui/flow_picker_spec.cr`.
#
# Comments are stripped first. The comment above the fetch NAMES `recent_flows` to explain why
# the call moved, so a whole-body `includes?` would pass on the strength of that prose.
private def comparer_pick_body : String
  path = File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner", "comparer.cr")
  lines = File.read(path).lines.reject(&.lstrip.starts_with?('#'))
  start = lines.index(&.includes?("def comparer_pick"))
  start.should_not be_nil, "comparer_pick is gone — this scan rotted before the rule did"
  rest = lines[start.not_nil! + 1..]
  stop = rest.index { |l| l.rstrip == "  end" }
  stop.should_not be_nil, "comparer_pick has no terminating end at method indentation"
  rest[0...stop.not_nil!].join('\n')
end

describe "the Comparer flow picker's row source" do
  it "applies the Scope lens in the query, before the row limit" do
    comparer_pick_body.should match(/store\.search\(\s*@scope\.filter\s*,\s*\d+/)
  end

  it "keeps no unlensed snapshot path, at any limit" do
    # Matched loosely on purpose: `recent_flows(1000)` restores the exact bug this pins.
    comparer_pick_body.should_not contain("recent_flows")
  end

  it "tells the picker its rows were lensed, so an empty card can say which emptiness it is" do
    comparer_pick_body.should match(/FlowPicker\.new\([^\n]*scoped:/)
  end

  it "surfaces a failed lens query instead of degrading it to an empty picker" do
    # store#search defaults to swallowing a SQLite failure and returning [] (the live render
    # loop must never crash). Here that degrade is indistinguishable from "nothing in scope".
    comparer_pick_body.should contain("raise_on_error: true")
  end
end
