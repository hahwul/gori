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

  # Both surfaces list from `Registry#for_view`; the space menu keeps only the lettered rows,
  # and draws a family member one level down, under its family's row (#1274 WP9).
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
        menu.entries.compact_map(&.verb).map(&.id).sort!.should eq(lettered.map(&.id).sort!)
        families = menu.entries.compact_map(&.family).map(&.id)
        palette.tab_actions.compact_map(&.family).uniq!.each { |fid| families.should contain(fid) }
      end
    end
  end

  # `menu: :palette` (#1282): the palette's typed search lists the verb from its own view, and
  # the space menu lists it at neither level. Swept like the example above.
  it "lists a palette-only verb in the palette's tab actions and nowhere in the space menu" do
    ctx = FakeExecContext.new
    ctx.selected = 5_i64
    menu = SpaceMenu.new(reg)
    found = Set(String).new
    reg.map(&.scope).uniq!.each do |scope|
      subtabs = reg.has_section?(scope, :subtab)
      reg.select { |v| v.scope == scope }.map(&.section).uniq!.each do |section|
        here = ActionContext.new(scope, section, subtabs)
        palette = PaletteState.new(reg)
        palette.capture(here, ctx)
        placed = palette.tab_actions.select(&.palette_only?).map(&.id)
        found.concat(placed)
        menu.open(here.scope, here.section, ctx, subtabs: here.subtabs)
        (menu.entries.compact_map(&.verb).map(&.id) & placed).should be_empty
        menu.entries.compact_map(&.family).each do |f|
          menu.descend(f)
          (menu.entries.compact_map(&.verb).map(&.id) & placed).should be_empty
          menu.open(here.scope, here.section, ctx, subtabs: here.subtabs)
        end
      end
    end
    %w[history.grpc-reflect discover.next-run env.edit-prefix issue.severity-up].each { |id| found.should contain(id) }
  end
end
