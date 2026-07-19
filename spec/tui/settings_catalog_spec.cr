require "../spec_helper"

include Gori::Tui

# The full set of symbols Runner#open_settings knows how to dispatch (form sections +
# the four dedicated overlays). If a catalog entry named a symbol outside this set, the
# palette verb and the tab opener would both land on the "coming soon (TODO)" toast.
KNOWN_SETTINGS_SECTIONS = [
  :network, :editor, :theme, :layout, :statusline, :display, :notifications, :general,
  :tabs, :hosts, :env, :hotkeys,
]

# SettingsCatalog is the single source of truth both the Ctrl-P palette and the Settings
# tab read. These tests guard the invariants that keep the two surfaces from drifting:
# every catalog entry must be a real palette verb AND a real open_settings target, and
# every inline (:form) section must have fields the shared engine knows how to render.
describe Gori::Tui::SettingsCatalog do
  it "registers exactly one palette verb per catalog section (ids match)" do
    registry = Gori::Verbs.registry
    SettingsCatalog.all.each do |s|
      registry[s.id]?.should_not be_nil # the loop in verbs/core.cr must have registered it
      registry[s.id].category.should eq(Gori::Verb::Category::Settings)
    end
    # …and no stray settings.* verb exists that the catalog doesn't back.
    settings_ids = registry.select(&.category.settings?).map(&.id).sort
    settings_ids.should eq(SettingsCatalog.all.map(&.id).sort)
  end

  it "only names sections open_settings can actually dispatch" do
    SettingsCatalog.all.each { |s| KNOWN_SETTINGS_SECTIONS.should contain(s.sym) }
  end

  it "gives every inline (:form) section fields the shared engine can render" do
    SettingsCatalog.all.select(&.kind.==(:form)).each do |s|
      SettingsView::SECTIONS[s.sym]?.should_not be_nil # render_fields_into reads this
      SettingsView::SECTIONS[s.sym].empty?.should be_false
    end
  end

  it "assigns every tab-visible section to a declared group" do
    group_syms = SettingsCatalog::GROUPS.map(&.first)
    SettingsCatalog.all.select(&.in_tab).each { |s| group_syms.should contain(s.group) }
  end

  it "yields a non-empty, in_tab-only member list for each group (drives the sub-tabs)" do
    SettingsCatalog::GROUPS.each do |(sym, _label)|
      members = SettingsCatalog.sections_in(sym)
      members.empty?.should be_false
      members.all?(&.in_tab).should be_true
    end
  end

  it "keeps the Hostnames section out of the tab (reachable via Network's opener field)" do
    hosts = SettingsCatalog.all.find(&.sym.==(:hosts)).not_nil!
    hosts.in_tab.should be_false
    SettingsCatalog.sections_in(hosts.group).map(&.sym).should_not contain(:hosts)
  end
end
