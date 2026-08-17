require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The TUI half of the session-slot surfaces (PR #10): the `session:NAME` top-bar chip, the
# picker behind it, and the identities card's write path.
#
# There is no Runner in any spec in this repo (`Runner.new` appears nowhere under spec/) — it
# owns a terminal — so the picker's open-site and the controller's write are pinned by reading
# the source, the way spec/tui/subtab_find_key_spec.cr does. Comments are stripped first: a
# comment explaining a rule contains the tokens the rule looks for, and a whole-file
# `includes?` would pass on the strength of its own prose.
private def slot_code(*parts : String) : Array(String)
  File.read(File.join(__DIR__, "..", "..", "src", "gori", *parts)).lines.reject(&.lstrip.starts_with?('#'))
end

describe "the session slot chip" do
  it "is absent while nothing is active — as-captured is the default" do
    rect = Rect.new(0, 0, 110, 1)
    off = MemoryBackend.new(110, 1)
    Chrome.render_top_bar(Screen.new(off), rect, project: "acme", scope: "scope:2",
      listen: "127.0.0.1:8080")
    off.row(0).should_not contain("session:")
  end

  it "names the active slot in WORDS, so the signal survives a hue-collapsing palette" do
    rect = Rect.new(0, 0, 110, 1)
    on = MemoryBackend.new(110, 1)
    Chrome.render_top_bar(Screen.new(on), rect, project: "acme", scope: "scope:2",
      listen: "127.0.0.1:8080", session: "session:admin")
    on.row(0).should contain("session:admin")
  end

  it "is clickable, and resolves to its own tag" do
    rect = Rect.new(0, 0, 120, 1)
    args = {scope: "scope:2", listen: "127.0.0.1:8080", session: "session:admin"}
    r = Chrome.top_bar_chip_rect(rect, :session, **args).not_nil!
    Chrome.top_bar_chip_at(rect, r.x, 0, **args).should eq(:session)
    Chrome.top_bar_chip_at(rect, r.right - 1, 0, **args).should eq(:session)
  end

  it "opens the picker on a click, and not some other chip's action" do
    mouse = slot_code("tui", "runner", "mouse.cr")
    arm = mouse.index(&.includes?("when :session"))
    arm.should_not be_nil, "the session chip lost its click handler"
    mouse[arm.not_nil!].should contain("open_session_slots")
  end
end

describe "the session slot picker" do
  it "is reachable from the palette as a Global verb" do
    verb = Gori::Verbs.registry["session.slot"]?
    verb.should_not be_nil
    verb.not_nil!.scope.should eq(Gori::Verb::Scope::Global)
    verb.not_nil!.hidden?.should be_false
  end

  it "always offers `as captured`, so deactivating is reachable in an empty project" do
    # Row 0 is the way BACK to sending under the request's own session. Without it the only
    # exit from an overlay would be restarting gori.
    rows = slot_code("tui", "runner", "session_slots.cr")
    build = rows.index(&.includes?("def session_slot_rows"))
    build.should_not be_nil
    rows[build.not_nil!, 6].join('\n').should contain("as captured")
  end

  it "activates by NAME, never by row position" do
    # The list can be edited from the Authorize card, `gori run session` or MCP between the
    # card opening and ↵; activating "whatever is third now" would send the wrong credential.
    body = slot_code("tui", "runner", "session_slots.cr").join('\n')
    body.should contain("list[i - 1]?.try(&.name)")
  end

  it "renders the overlay SUMMARY, which is header names only" do
    # `SessionSlot#summary` is the names-only projection the identities card already uses. A
    # picker that printed values would paint a credential on screen.
    slot = Gori::SessionSlot.new("admin", [{"Cookie", "session=SUPERSECRET"}])
    slot.summary.should eq("sets Cookie")
    slot.summary.should_not contain("SUPERSECRET")
    slot_code("tui", "runner", "session_slots.cr").join('\n').should contain("slot.summary")
  end
end

describe "the identities card's write path" do
  it "goes through the live slot registry, not the settings row underneath it" do
    # The card used to `set_setting(Store::AUTHORIZE_IDENTITIES_KEY, …)` directly, which left
    # the registry `Bindings` and `Env.overlay_slot` hold with the pre-edit list: the Authorize
    # tab and a Repeater send then disagreed about what "admin" was until the project reopened.
    body = slot_code("tui", "controllers", "authorize_controller.cr").join('\n')
    replace = body[/def replace_identities.*?\n    end/m]
    replace.should contain("session.slots.save")
    replace.should_not contain("set_setting")
    # And it READS the same registry, so a slot added from the CLI/MCP/picker shows up here.
    load = body[/def identities .*?\n    end/m]
    load.should contain("session.slots.slots")
  end
end

describe "the Repeater's send line" do
  it "names the active slot, because the overlay is invisible in the editor" do
    # A slot's headers are applied at `Repeater::Sender`, AFTER the pane's bytes — so the
    # editor shows one request and the wire carries another. The status line is where the two
    # are reconciled.
    body = slot_code("tui", "controllers", "repeater_controller.cr").join('\n')
    line = body[/@host\.status\("sending.*?\n/]
    line.should contain("sending_as")
    body[/def sending_as.*?\n    end/m].should contain("Gori::Env.active_slot_name")
  end
end
