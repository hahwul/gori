require "../spec_helper"
require "../support/fake_context"

# The space-menu half of sub-tab multi-select (#683): two rows per workbench strip, on nine
# scopes, sharing two generic intents. The registry-wide sweeps already prove reachability and
# that each dispatches an intent; what is pinned here is the SHAPE the nine registrations must
# keep in step — mirroring `spec/verbs/sitemap_spec.cr`'s mark block.
describe "sub-tab mark verbs" do
  r = Gori::Verbs.registry

  # {verb id prefix, the tab symbol the `available` gate reads}
  strips = {
    "repeater" => :repeater, "fuzz" => :fuzzer, "mine" => :miner, "sequence" => :sequencer,
    "decoder" => :decoder, "jwt" => :jwt, "cookie" => :cookie, "comparer" => :comparer,
    "notes" => :notes,
  }

  it "registers the same pair on every strip that marks" do
    strips.each_key do |prefix|
      r["#{prefix}.subtab-mark-all"].section.should eq(:subtab)
      r["#{prefix}.subtab-mark-clear"].section.should eq(:subtab)
    end
  end

  it "routes both rows to the two generic intents" do
    strips.each_key do |prefix|
      verb_intents(r, "#{prefix}.subtab-mark-all").should eq([:subtab_mark_all])
      verb_intents(r, "#{prefix}.subtab-mark-clear").should eq([:subtab_mark_clear])
    end
  end

  it "is menu-only, on the letters the four list surfaces already use" do
    # `T` and `N` are what History, Issues and the Intercept queue spend on mark-all and
    # Clear marks; they are free in COMMON ∪ :subtab on all nine scopes (validate_menu_keys!
    # would refuse the registry otherwise, so this is the readable form of that gate).
    strips.each_key do |prefix|
      all = r["#{prefix}.subtab-mark-all"]
      clear = r["#{prefix}.subtab-mark-clear"]
      all.chords.should be_empty
      clear.chords.should be_empty
      all.menu_key.should eq('T')
      clear.menu_key.should eq('N')
    end
  end

  it "does not offer a toggle row — `t` is a strip key" do
    r.none?(&.id.ends_with?(".subtab-mark-toggle")).should be_true
  end

  it "offers mark-all only with two or more sub-tabs, and Clear marks only while marks are set" do
    strips.each do |prefix, tab|
      ctx = FakeExecContext.new
      ctx.current_tab = tab
      all = r["#{prefix}.subtab-mark-all"]
      clear = r["#{prefix}.subtab-mark-clear"]

      ctx.subtab_search_tab_count = 1
      all.available?(ctx).should be_false, "#{prefix}: mark-all offered over a lone sub-tab"
      ctx.subtab_search_tab_count = 2
      all.available?(ctx).should be_true

      clear.available?(ctx).should be_false, "#{prefix}: Clear marks offered with nothing marked"
      ctx.subtab_marks = 1
      clear.available?(ctx).should be_true

      # …and neither on another tab, whatever the counts say.
      ctx.current_tab = :history
      all.available?(ctx).should be_false
      clear.available?(ctx).should be_false
    end
  end

  it "keeps the Repeater strip's tag entry where it was" do
    # Tagging left the strip's bare `t` (that key marks now) but NOT the menu: `space ▸ t` on
    # the strip still opens the prompt, and with marks set it tags every marked sub-tab.
    tag = r["repeater.tag-subtab"]
    tag.section.should eq(:subtab)
    tag.menu_key.should eq('t')
  end
end
