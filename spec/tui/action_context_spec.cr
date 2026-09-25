require "../spec_helper"
require "../support/fake_context"

include Gori::Tui

# The one "what can I do here" both `Space` and `Ctrl-P` read (#1282).
describe Gori::Tui::ActionContext do
  reg = Gori::Verbs.registry

  it "names the focused pane's section from the body" do
    here = ActionContext.capture(reg, detail: false, focus: :body, scope: Gori::Verb::Scope::Repeater,
      pane_section: :response, banner: "2 MARKED")
    here.scope.should eq(Gori::Verb::Scope::Repeater)
    here.section.should eq(:response)
    here.subtabs.should be_true # Repeater has a sub-tab family
    here.banner.should eq("2 MARKED")
  end

  it "offers the tab's own :tab actions from the tab bar, else COMMON" do
    ActionContext.capture(reg, detail: false, focus: :menu, scope: Gori::Verb::Scope::Repeater,
      pane_section: :request).section.should eq(:tab)
    ActionContext.capture(reg, detail: false, focus: :menu, scope: Gori::Verb::Scope::Body,
      pane_section: :common).section.should eq(:common)
  end

  it "names the strip from the sub-tab strip" do
    ActionContext.capture(reg, detail: false, focus: :subtabs, scope: Gori::Verb::Scope::Repeater,
      pane_section: :request).section.should eq(:subtab)
  end

  it "is the detail's own scope while a History detail is open" do
    here = ActionContext.capture(reg, detail: true, focus: :body, scope: Gori::Verb::Scope::Body, pane_section: :common)
    here.scope.should eq(Gori::Verb::Scope::HistoryDetail)
    here.section.should eq(:common)
    here.subtabs.should be_false
  end

  # Both surfaces list from `Registry#for_view`; the space menu keeps only the lettered rows.
  # Swept over every scope and section so the two can never drift apart again.
  it "gives the space menu exactly the palette's tab actions that carry a letter" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64
    menu = SpaceMenu.new(reg)
    reg.map(&.scope).uniq!.each do |scope|
      sections = reg.select { |v| v.scope == scope }.map(&.section).uniq!
      subtabs = reg.has_section?(scope, :subtab)
      sections.each do |section|
        here = ActionContext.new(scope, section, subtabs)
        palette = PaletteState.new(reg)
        palette.capture(here, ctx)
        menu.open(here.scope, here.section, ctx, subtabs: here.subtabs)
        lettered = palette.tab_actions.select(&.menu_key)
        menu.entries.map(&.id).sort!.should eq(lettered.map(&.id).sort!)
      end
    end
  end
end
