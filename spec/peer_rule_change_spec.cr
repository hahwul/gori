require "./spec_helper"
require "file_utils"

# #772 — a PEER's rule edit has to reach the operator, and this session's OWN edits must not.
#
# The split that decides it is structural, not a flag: every local editor goes through the private
# `refresh`, and only a peer adoption or a re-read reaches the public `reload`. These examples pin
# both halves, plus the property that makes the re-readers safe — a peer change is RECORDED on the
# object, so `on_enter` or the `r` key reloading first cannot consume the announcement the operator
# was owed.
#
# "Peer" here is a SECOND live engine over the same store, the idiom
# `spec/tui/rewriter_peer_reload_anchor_spec.cr` uses: it lands in the row without going through
# the object under test, which is exactly what another process does.

private def with_store(&)
  path = File.tempname("gori-peer-change", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# The global rule library is process-wide (Settings) and a file as much as it is memory — see the
# long note in `spec/rules_spec.cr`. Same isolation here.
private def with_globals(&)
  before = Gori::Settings.rewriter_rules
  counter = Gori::Settings.rewriter_next_rule_id
  prev_home = ENV["GORI_HOME"]?
  dir = File.tempname("gori-peer-change-globals")
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

private def add_rule(engine : Gori::Rules, name : String,
                     scope : Gori::Store::RuleScope = Gori::Store::RuleScope::Project) : Bool
  engine.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
    "pattern-#{name}", "x", name: name, scope: scope)
end

describe "Gori::Rules peer-change tracking" do
  it "records a peer's write, and hands it over exactly once" do
    with_globals do
      with_store do |store|
        live = Gori::Rules.load(store)
        add_rule(Gori::Rules.load(store), "theirs") # the peer, through its own engine
        live.reload
        change = live.take_peer_change.not_nil!
        change.changed.should eq(1)
        change.enabled.should eq(1)
        # Drained: a second surface asking gets nothing, and neither does the next tick.
        live.take_peer_change.should be_nil
      end
    end
  end

  it "says nothing about THIS session's own edits" do
    # The operator adding, toggling and reordering their own rules is not news to them, and each
    # of these is a `data_version` bump that the tick will reload right behind.
    with_globals do
      with_store do |store|
        live = Gori::Rules.load(store)
        add_rule(live, "mine")
        add_rule(live, "mine2")
        id = live.rules.first.id
        live.toggle(id)
        live.move(live.rules.last.id, -1)
        live.take_peer_change.should be_nil
        # And the reload that follows every local edit on the tick finds nothing left over.
        live.reload
        live.take_peer_change.should be_nil
      end
    end
  end

  it "says nothing on the poll that finds no change at all" do
    # This is the common case: the tick fires ~1.3×/sec under live capture, on this session's own
    # captures as much as on a peer's writes.
    with_globals do
      with_store do |store|
        live = Gori::Rules.load(store)
        add_rule(live, "mine")
        5.times { live.reload }
        live.take_peer_change.should be_nil
      end
    end
  end

  it "does not let a re-read eat the announcement it owes" do
    # The Rewriter tab's `on_enter` and its `r` key both reload. If the change were RETURNED
    # rather than recorded, whichever of those ran first would swallow it and the operator would
    # never be told — the failure `spec/tui/peer_edit_sync_spec.cr` pins for the Issues notes.
    with_globals do
      with_store do |store|
        live = Gori::Rules.load(store)
        add_rule(Gori::Rules.load(store), "theirs")
        live.reload # the tab's own re-read, verdict ignored
        live.reload # the tick, some frames later
        live.take_peer_change.not_nil!.changed.should eq(1)
      end
    end
  end

  it "folds a burst of peer writes into one change" do
    # An agent writing three rules in a row lands three adoptions. They add up rather than
    # replacing, so the line the operator gets counts the whole burst.
    with_globals do
      with_store do |store|
        live = Gori::Rules.load(store)
        peer = Gori::Rules.load(store)
        3.times do |i|
          add_rule(peer, "theirs#{i}")
          live.reload
        end
        change = live.take_peer_change.not_nil!
        change.changed.should eq(3)
        change.enabled.should eq(3)
      end
    end
  end

  it "sees a peer's REORDER, which adds and removes nothing" do
    # Precedence decides which of two rules touching the same header wins, so a `move` is a real
    # change to what leaves this session — and it is invisible to a membership diff.
    with_globals do
      with_store do |store|
        live = Gori::Rules.load(store)
        add_rule(live, "first")
        add_rule(live, "second")
        live.take_peer_change.should be_nil

        peer = Gori::Rules.load(store)
        peer.move(peer.rules.last.id, -1).should be_true
        live.reload
        change = live.take_peer_change.not_nil!
        change.changed.should eq(0)
        change.reordered.should be_true
      end
    end
  end

  it "stays silent for the factory reset, the one local edit that comes in through reload" do
    # `apply_factory_reset` wipes the global library and reloads. Announcing would tell the
    # operator a peer had just deleted every global rule they themselves reset.
    with_globals do
      with_store do |store|
        live = Gori::Rules.load(store)
        add_rule(live, "global", scope: Gori::Store::RuleScope::Global)
        Gori::Settings.rewriter_rules = [] of Gori::Settings::RewriterRule
        live.reload(announce: false)
        live.rules.should be_empty
        live.take_peer_change.should be_nil
      end
    end
  end
end

describe "Gori::Bindings peer-change tracking" do
  it "records a peer's extract rule and stays quiet about its own" do
    with_store do |store|
      live = Gori::Bindings.load(store, nil)
      live.add("MINE", "true", Gori::ExtractKind::Header, "x-mine").should be_nil
      live.take_peer_change.should be_nil

      Gori::Bindings.load(store, nil).add("THEIRS", "true", Gori::ExtractKind::Header, "x-theirs").should be_nil
      live.reload
      change = live.take_peer_change.not_nil!
      change.changed.should eq(1)
      change.enabled.should eq(2)
      live.take_peer_change.should be_nil
    end
  end

  it "is not fooled by the revision, which moves on ordinary traffic" do
    # `rev` bumps on every successful extraction and on every value clear, and `rows` carry the
    # extracted VALUES — so either would report a peer change off nothing but a captured response.
    # The RULES are the axis, which is why the diff compares those and nothing else.
    with_store do |store|
      live = Gori::Bindings.load(store, nil)
      live.add("TOKEN", "true", Gori::ExtractKind::Header, "x-token").should be_nil
      live.take_peer_change.should be_nil
      before = live.rev
      live.clear_all
      live.rev.should_not eq(before)
      live.reload
      live.take_peer_change.should be_nil
    end
  end
end
