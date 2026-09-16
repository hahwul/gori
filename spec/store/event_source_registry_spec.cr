require "../spec_helper"

# `events.source` is a FREE STRING — `insert_event` writes whatever it is handed — and three
# surfaces narrow on it: the Activity pane's `s` chip (`ProjectView::ACT_SOURCES`), that chip's
# keybinding help, and MCP `list_events{source}`. All three read `Store::EVENT_SOURCES`, which is
# what keeps them from drifting apart.
#
# What nothing kept in step was the list against the WRITERS. `runner/evidence.cr` started
# writing `issues` (an operator froze a copy of a flow onto an issue) without registering it, and
# nothing complained: the rows landed in the feed, the `s` chip could never narrow to them, and
# `list_events{source:"issues"}` came back INVALID_ARGUMENT naming a set that omitted a source the
# project writes. So the registry is checked against the tree, the way `peer_notices_spec` pins
# its two wirings.
private def each_src_line(&)
  root = File.join(__DIR__, "..", "..", "src")
  Dir.glob(File.join(root, "**", "*.cr")).each do |path|
    rel = Path[path].relative_to(root).to_s
    File.read(path).each_line do |line|
      next if line.lstrip.starts_with?('#')
      yield rel, line
    end
  end
end

private def event_source_literals : Hash(String, Array(String))
  found = Hash(String, Array(String)).new { |h, k| h[k] = [] of String }
  each_src_line do |rel, line|
    line.scan(/insert_event\(\s*"([^"]+)"/) { |m| found[m[1]] << rel }
  end
  found
end

# `insert_event` is not the only door: `env_migration/store.cr` writes the feed with a raw
# INSERT on its own migration connection, deliberately (the caller's handle is read-only on a
# read-only `gori run`, and an event written through it is dropped without a word). A raw
# statement is invisible to the grep above, so a future one coining its own source word would
# reproduce the `issues` bug with this file green. The set of files allowed to do it is pinned
# instead — adding one is a decision, and it has to come with registering what it writes.
private def raw_event_insert_files : Array(String)
  files = [] of String
  each_src_line do |rel, line|
    next if rel == "gori/store/event_log.cr" # the sink's own statement, which IS `insert_event`
    files << rel if line.includes?("INSERT INTO events")
  end
  files.uniq.sort!
end

# The producers that pass a CONSTANT rather than a literal, which the grep cannot see through.
# Kept tiny and explicit: each entry is a claim that this source has a writer, checked by the
# reverse assertion below.
private INDIRECT_SOURCES = {"config" => "config_log.cr (ConfigLog::SOURCE)"}

describe "Store::EVENT_SOURCES" do
  it "registers every source the tree actually writes" do
    written = event_source_literals
    written.should_not be_empty # the grep itself still matches something
    unregistered = written.reject { |source, _| Gori::Store::EVENT_SOURCES.includes?(source) }
    # Named, not counted: the fix is to add the word to EVENT_SOURCES (or to stop writing it).
    unregistered.should eq({} of String => Array(String))
  end

  # The other direction, and the one `EVENT_SOURCES`' own doc names first: "A filter offering a
  # source nothing writes returns an empty feed that reads as 'nothing happened'." Deleting a
  # producer leaves its word on the `s` chip and in MCP's enum, and the operator reads the empty
  # result as a fact about their project.
  it "offers no source that nothing writes" do
    writers = event_source_literals.keys.to_set | INDIRECT_SOURCES.keys.to_set
    orphaned = Gori::Store::EVENT_SOURCES.reject { |source| writers.includes?(source) }
    orphaned.should eq([] of String)
  end

  it "keeps the raw-INSERT writers to the one file that needs one" do
    raw_event_insert_files.should eq(["gori/env_migration/store.cr"])
  end

  it "carries no duplicate and no blank" do
    Gori::Store::EVENT_SOURCES.uniq.should eq(Gori::Store::EVENT_SOURCES)
    Gori::Store::EVENT_SOURCES.none?(&.blank?).should be_true
  end

  # The pane's chip and MCP's closed filter are the two consumers, and both are generated from
  # the list rather than spelled again — so a registered source is reachable from both by
  # construction. This pins that they still are.
  it "is what the Activity pane's chip cycles" do
    Gori::Tui::ProjectView::ACT_SOURCES.should eq([nil] + Gori::Store::EVENT_SOURCES)
  end
end

describe "Store.event_level" do
  # The four job controllers hand their level to the notification centre AND to the feed, whose
  # vocabularies differ by exactly one word. Spelling it straight through made the Sequencer the
  # one producer writing "warning", which the pane then had to match on top of "warn".
  it "spells the notification centre's :warning as the feed's warn" do
    Gori::Store.event_level(:warning).should eq("warn")
  end

  it "passes every other level through unchanged" do
    {:info, :success, :error}.each do |level|
      token = Gori::Store.event_level(level)
      token.should eq(level.to_s)
      Gori::Store::EVENT_LEVELS.should contain(token)
    end
  end
end
