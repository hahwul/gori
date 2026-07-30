require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

# The TLS-passthrough list (#497): the drill-down behind the `bypass:N` top-bar chip.
#
# Everything is driven through OverlayHarness, whose `overlay` getter is typed
# `Gori::Tui::Overlay` — deliberately, and not just for style. Crystal resolves a call on a
# concrete type to that type's own method, so a subclass that misspells a contract method
# (`handle_click(area, x, y)` with the wrong arity, say) SHADOWS the base one silently and a
# spec calling it on the concrete class asserts the shadow, not what the Runner will dispatch
# to. Asserting through the base-typed reference is what makes these examples cover the real
# seam.
private def seed(hosts : Array({String, String}), patterns : Array(String) = ["*.push.acme.test"], &)
  prev = Gori::Settings.tls_passthrough
  begin
    Gori::Settings.tls_passthrough = patterns
    Gori::Settings.reset_passthrough_inventory
    hosts.each { |(host, _)| Gori::Settings.tls_passthrough?(host) }
    yield
  ensure
    Gori::Settings.tls_passthrough = prev
    Gori::Settings.reset_passthrough_inventory
  end
end

describe PassthroughOverlay do
  it "exposes the chrome the Runner's collapsed title/hint ladders read off an overlay" do
    seed([] of {String, String}) do
      OverlayHarness.new(PassthroughOverlay.new).assert_chrome(OverlayKind::Passthrough, "TLS PASSTHROUGH")
    end
  end

  it "esc closes without committing — there is nothing to apply" do
    seed([{"a.push.acme.test", ""}]) do
      h = OverlayHarness.new(PassthroughOverlay.new)
      h.press(Termisu::Input::Key::Escape).should eq(:closed)
      h.commits.should eq(0)
    end
  end

  it "renders host, pattern and connection count on one row (constraint (c))" do
    # The pattern is the field the whole overlay exists to carry: the operator's next move
    # after seeing a bypassed host is to find the rule doing it. It gets its own column here
    # rather than an aside that a narrow pane can drop whole (which is what ruled the Sitemap
    # tab out).
    seed([{"a.push.acme.test", ""}]) do
      Gori::Settings.tls_passthrough?("a.push.acme.test") # a second connection
      mb = OverlayHarness.new(PassthroughOverlay.new).render
      mb.contains?("a.push.acme.test").should be_true
      mb.contains?("*.push.acme.test").should be_true
      mb.contains?("2 conns").should be_true
    end
  end

  it "reads differently for 'nothing bypassed yet' and 'no rules configured'" do
    # Two states the same empty list would otherwise conflate. The second is answerable only
    # from Settings.tls_passthrough, and it is the one that means this list can never fill.
    seed([] of {String, String}, patterns: ["*.push.acme.test"]) do
      OverlayHarness.new(PassthroughOverlay.new).rendered?("no host has been bypassed yet").should be_true
    end
    seed([] of {String, String}, patterns: [] of String) do
      OverlayHarness.new(PassthroughOverlay.new).rendered?("no TLS passthrough rules configured").should be_true
    end
  end

  it "says the list is session-wide, since the chip it opens from sits in per-project chrome" do
    seed([{"a.push.acme.test", ""}]) do
      OverlayHarness.new(PassthroughOverlay.new).rendered?("session-wide").should be_true
    end
  end

  it "says so when the inventory cap truncated the list, instead of showing N of more" do
    seed([] of {String, String}, patterns: ["acme.test"]) do
      (Gori::Settings::PASSTHROUGH_INVENTORY_MAX + 3).times { |i| Gori::Settings.tls_passthrough?("h#{i}.acme.test") }
      OverlayHarness.new(PassthroughOverlay.new).rendered?("not listed").should be_true
    end
  end

  it "scrolls with ↑/↓ and j/k without ever closing or committing" do
    seed([{"a.push.acme.test", ""}, {"b.push.acme.test", ""}, {"c.push.acme.test", ""}]) do
      ov = PassthroughOverlay.new
      h = OverlayHarness.new(ov)
      h.press(Termisu::Input::Key::Down).should eq(:open)
      h.press(Termisu::Input::Key::LowerJ, 'j').should eq(:open)
      h.press(Termisu::Input::Key::Down).should eq(:open) # clamped at the last row
      h.press(Termisu::Input::Key::Up).should eq(:open)
      h.commits.should eq(0)
    end
  end

  it "wheel scrolls the list (the base class routes handle_wheel to move)" do
    seed([{"a.push.acme.test", ""}, {"b.push.acme.test", ""}]) do
      h = OverlayHarness.new(PassthroughOverlay.new)
      h.wheel(3)
      h.open?.should be_true
    end
  end

  it "r re-snapshots the live inventory, so a bypass while it is open shows up" do
    seed([{"a.push.acme.test", ""}]) do
      ov = PassthroughOverlay.new
      ov.hosts.size.should eq(1)
      h = OverlayHarness.new(ov)
      Gori::Settings.tls_passthrough?("b.push.acme.test")
      h.press(Termisu::Input::Key::LowerR, 'r').should eq(:open)
      ov.hosts.size.should eq(2)
      h.rendered?("b.push.acme.test").should be_true
    end
  end

  it "a row click selects but never commits; a click outside dismisses" do
    # Read-only: closing on a row click would read as "that did something". Assert the RAW
    # vocabulary through the base-typed reference, because :stay vs a truthy :commit both
    # collapse to a shell-visible outcome the harness alone cannot distinguish.
    seed([{"a.push.acme.test", ""}, {"b.push.acme.test", ""}]) do
      h = OverlayHarness.new(PassthroughOverlay.new)
      box = h.box.not_nil!
      h.overlay.handle_click(h.area, box.x + 3, box.y + 3).should eq(:stay)
      h.click_in_box(3, 3).should eq(:open)
      h.commits.should eq(0)

      away = OverlayHarness.new(PassthroughOverlay.new)
      away.overlay.handle_click(away.area, 0, 0).should eq(:cancel)
      away.click(0, 0).should eq(:closed)
      away.commits.should eq(0)
    end
  end

  it "^P hands off to the palette without the shell dropping it twice" do
    seed([{"a.push.acme.test", ""}]) do
      ov = PassthroughOverlay.new
      hops = 0
      ov.on_palette = -> { hops += 1; nil }
      h = OverlayHarness.new(ov)
      # ^P must stay :stay: the real open-site's closure calls leave_overlay itself, so a
      # :cancel here would make the shell close a modal it has already dropped.
      h.press(Termisu::Input::Key::LowerP, 'p', ctrl: true).should eq(:open)
      hops.should eq(1)
    end
  end

  it "gives up rather than drawing a broken card in a tiny area" do
    seed([{"a.push.acme.test", ""}]) do
      # Wide but far too short for a card — the branch overlay_box answers nil on. (Narrow
      # works too, but then the fallback line is itself truncated and proves less.)
      tiny = Rect.new(0, 0, 60, 4)
      h = OverlayHarness.new(PassthroughOverlay.new, area: tiny)
      h.box.should be_nil
      h.rendered?("larger window").should be_true
      # With no box the base contract turns every click into a dismiss.
      h.overlay.handle_click(tiny, 2, 2).should eq(:cancel)
    end
  end
end
