require "../spec_helper"
require "../support/memory_backend"
require "file_utils"

include Gori::Tui

# The nine-slot bar: the cap itself (a setting, default on), the numbers it hands out, and the
# one-time migration that moves an existing operator onto it.
#
# `Runner.new` owns a terminal and appears nowhere under spec/, which is exactly why the
# migration is a CLASS method (`Runner.settle_tab_slots`, like `Runner.quit_decision`): it is
# a policy over `Settings` with no terminal behind it, so the thing a user actually sees on
# their first launch after upgrading can be driven here rather than reasoned about.

# Settings is a process-wide singleton, so every example that touches it restores what it
# found — and points GORI_HOME at a scratch dir, since `settle_tab_slots` persists.
private def with_tab_settings(&)
  dir = File.tempname("gori-tab-slots")
  Dir.mkdir_p(dir)
  prev_home = ENV["GORI_HOME"]?
  prev = {Gori::Settings.tab_slots?, Gori::Settings.tab_prefs}
  begin
    ENV["GORI_HOME"] = dir
    yield
  ensure
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    Gori::Settings.tab_slots, Gori::Settings.tab_prefs = prev
    FileUtils.rm_rf(dir)
  end
end

# A saved layout with `n` visible tabs, in catalog order — the shape an older build persisted.
private def prefs_with_visible(n : Int32) : Array({String, Bool})
  Chrome::TABS.map_with_index { |(sym, _), i| {sym.to_s, i < n} }
end

# The pre-slots factory default, spelled the way settings:tabs' ↵ persisted it.
private def legacy_default_prefs : Array({String, Bool})
  Chrome::TABS.map { |(sym, _)| {sym.to_s, !Chrome::LEGACY_DEFAULT_HIDDEN.includes?(sym)} }
end

describe "the nine-slot cap as a setting" do
  it "truncates a fifteen-tab layout when the cap is ON" do
    with_tab_settings do
      Gori::Settings.tab_slots = true
      vis = Chrome.visible_tabs(prefs_with_visible(15)).map(&.first)
      vis.size.should eq(Chrome::MAX_SLOTS)
      vis.should eq(Chrome::TABS.first(9).map(&.first))
    end
  end

  it "leaves the same layout alone when the cap is OFF" do
    with_tab_settings do
      Gori::Settings.tab_slots = false
      vis, slots = Chrome.visible_slots(prefs_with_visible(15))
      vis.size.should eq(15) # the bar is unbounded again and scrolls with ‹ ›
      slots.should eq(15)
      # …but only nine DIGITS exist, so only nine tabs wear a number. A `12:` painted on a
      # tab no key reaches would be the bar lying about itself.
      Chrome.numbered_slots(slots).should eq(Chrome::MAX_SLOTS)
    end
  end

  it "numbers the first nine and nothing past them, cap off" do
    with_tab_settings do
      Gori::Settings.tab_slots = false
      rect = Rect.new(0, 0, 400, 1)
      tabs = Chrome.visible_tabs(prefs_with_visible(15))
      segs = Chrome.menu_segments(rect, tabs.first[0], tabs: tabs, numbered: true, slots: tabs.size)
      plain = Chrome.menu_segments(rect, tabs.first[0], tabs: tabs, numbered: false)
      segs.first(9).each_with_index { |(_, seg), i| seg.w.should eq(plain[i][1].w + 2) }
      segs[9][1].w.should eq(plain[9][1].w) # the tenth carries no number
    end
  end

  it "refuses the tenth ✓ only while the cap is on" do
    with_tab_settings do
      Gori::Settings.tab_prefs = [] of {String, Bool}
      Gori::Settings.tab_slots = true
      ov = TabsOverlay.new
      # The nine default slots are full, so showing a tenth is the refusal.
      hidden_row = (0...ov.entry_count).find { |i| ov.slot_of(i).nil? }.not_nil!
      ov.set_selected(hidden_row)
      ov.toggle_selected.should be_false

      Gori::Settings.tab_slots = false
      ov2 = TabsOverlay.new
      row = (0...ov2.entry_count).find { |i| ov2.slot_of(i).nil? }.not_nil!
      ov2.set_selected(row)
      ov2.toggle_selected.should be_true # unbounded: a tenth tab is fine
    end
  end

  it "still refuses to hide the LAST visible tab, either way" do
    with_tab_settings do
      Gori::Settings.tab_slots = false
      Gori::Settings.tab_prefs = Chrome::TABS.map_with_index { |(sym, _), i| {sym.to_s, i == 0} }
      ov = TabsOverlay.new
      ov.set_selected(0)
      ov.toggle_selected.should be_false
    end
  end

  it "names the slot in front of every tab on the bar, and nothing in front of the rest" do
    with_tab_settings do
      Gori::Settings.tab_prefs = [] of {String, Bool}
      Gori::Settings.tab_slots = true
      ov = TabsOverlay.new
      slots = (0...ov.entry_count).map { |i| ov.slot_of(i) }
      slots.compact.should eq((1..Chrome::MAX_SLOTS).to_a) # 1..9, in bar order
      slots.count(&.nil?).should eq(Chrome::TABS.size - Chrome::MAX_SLOTS)
    end
  end

  it "renumbers live as ⇧K/⇧J reorder" do
    with_tab_settings do
      Gori::Settings.tab_prefs = [] of {String, Bool}
      Gori::Settings.tab_slots = true
      ov = TabsOverlay.new
      ov.slot_of(0).should eq(1)
      ov.slot_of(1).should eq(2)
      ov.set_selected(0)
      ov.move_selected(1) # push slot 1 down past slot 2
      ov.slot_of(0).should eq(1)
      ov.slot_of(1).should eq(2)
      # the SYMBOLS swapped, which is the point: the numbers belong to positions, not tabs
      ov.to_prefs.first[0].should eq(Chrome::TABS[1][0].to_s)
    end
  end
end

describe "Runner.settle_tab_slots — the one-time migration" do
  it "says nothing on a fresh install" do
    with_tab_settings do
      Gori::Settings.tab_slots = true
      Gori::Settings.tab_prefs = [] of {String, Bool}
      Runner.settle_tab_slots.should be_nil
      Gori::Settings.tab_prefs.should be_empty
    end
  end

  it "hands the PRE-SLOTS default back to the defaults, silently" do
    with_tab_settings do
      Gori::Settings.tab_slots = true
      # settings:tabs' ↵ persisted the full catalog even when nothing was edited, so a config
      # that is exactly the old default means "I never chose these fifteen". Truncating it by
      # position would hand them Project…JWT — neither the bar they had nor the one we ship.
      Gori::Settings.tab_prefs = legacy_default_prefs
      Runner.settle_tab_slots.should be_nil
      Gori::Settings.tab_prefs.should be_empty # back to DEFAULT_HIDDEN's nine
      Chrome.visible_tabs(Gori::Settings.tab_prefs).map(&.first)
        .should eq([:project, :target, :history, :intercept, :repeater, :fuzzer,
                    :probe, :issues, :notes])
    end
  end

  it "keeps a CUSTOMISED operator's first nine, in their order, and names the six that folded" do
    with_tab_settings do
      Gori::Settings.tab_slots = true
      # Their own order, not the catalog's: Help first, then the rest of the old default.
      custom = [{"help", true}, {"notes", true}] + legacy_default_prefs
      before = Chrome.reconcile(custom, capped: false).select { |(_, _, v)| v }.map(&.first)
      before.size.should eq(15)

      notice = Runner.settle_tab_slots(prefs: custom).not_nil!

      kept = Chrome.visible_tabs(Gori::Settings.tab_prefs).map(&.first)
      kept.should eq(before.first(9)) # position truncation, in THEIR order
      kept.first.should eq(:help)

      folded = before[9..].map { |sym| Chrome.tab_label(sym) }
      folded.size.should eq(6)
      notice.should contain("6 tabs moved behind 0")
      folded.each { |label| notice.should contain(label) }
      notice.should contain("settings:tabs")
    end
  end

  it "says it once — the truncated layout is persisted, so the second launch is quiet" do
    with_tab_settings do
      Gori::Settings.tab_slots = true
      custom = [{"help", true}] + legacy_default_prefs
      Runner.settle_tab_slots(prefs: custom).should_not be_nil
      Runner.settle_tab_slots.should be_nil # same process, the prefs it just wrote
    end
  end

  it "says nothing at all while the cap is off" do
    with_tab_settings do
      Gori::Settings.tab_slots = false
      custom = [{"help", true}] + legacy_default_prefs
      Gori::Settings.tab_prefs = custom
      Runner.settle_tab_slots.should be_nil
      Chrome.visible_tabs(Gori::Settings.tab_prefs).size.should eq(15) # untouched
    end
  end
end
