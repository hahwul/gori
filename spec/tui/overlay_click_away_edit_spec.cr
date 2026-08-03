require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

# Click-away versus the open add/edit row, for the two settings editors that carry one.
#
# The keyboard path is already spec'd the safe way (overlay_c5_spec: "esc in the add row
# cancels the ROW, not the modal") — esc backs the sub-mode out and leaves the editor up.
# The MOUSE path used to return :cancel unconditionally, so a stray click outside the card
# both dropped what had been typed and took the whole editor down with it, with no toast.
# PreferencesOverlay#handle_click already routes click-away through its esc guard for
# exactly this reason; these lock the same shape onto the hostnames + env editors.
#
# Driving note: mnemonics branch on `ev.char`, so they are pressed with the real char
# attached (`type` would ride every char on Key::LowerA and miss nothing here, but the
# mnemonic itself has to carry its char).
private CA_ESC = Termisu::Input::Key::Escape
private CA_A   = Termisu::Input::Key::LowerA

private def ca_mnemonic(h : OverlayHarness, c : Char) : Symbol
  h.press(CA_A, c)
end

private def with_ca_hosts(entries : Array({String, String}), &)
  prev = Gori::Settings.hostname_overrides
  Gori::Settings.hostname_overrides = entries
  yield
ensure
  Gori::Settings.hostname_overrides = prev.not_nil!
end

private def with_ca_env(prefix : String, vars : Array({String, String}), &)
  prev_prefix = Gori::Settings.env_prefix
  prev_vars = Gori::Settings.env_vars
  Gori::Settings.env_prefix = prefix
  Gori::Settings.env_vars = vars
  yield
ensure
  Gori::Settings.env_prefix = prev_prefix.not_nil!
  Gori::Settings.env_vars = prev_vars.not_nil!
end

private def ca_hosts_editor : HostsOverlay
  ov = HostsOverlay.new
  ov.on_save = -> { true }
  ov.on_toast = ->(_m : String) { nil }
  ov
end

private def ca_env_editor : EnvOverlay
  ov = EnvOverlay.new
  ov.on_save = -> { true }
  ov.on_toast = ->(_m : String) { nil }
  ov
end

describe "HostsOverlay — click-away with an open add row" do
  it "cancels the ROW and keeps the editor up, exactly like esc" do
    with_ca_hosts([] of {String, String}) do
      ov = ca_hosts_editor
      h = OverlayHarness.new(ov)
      ca_mnemonic(h, 'a')
      h.type("10.0.0.1 staging.acme.test")
      # Raw vocabulary, not just the shell-visible outcome: :cancel here is what closed the
      # modal, and the harness would collapse it into the same :closed as a commit.
      h.overlay.handle_click(h.area, 0, 0).should eq(:stay)
      ov.adding?.should be_false      # the row backed out…
      ov.to_overrides.should be_empty # …uncommitted, as esc leaves it
    end
  end

  it "takes two clicks to leave, the second one from a clean list" do
    with_ca_hosts([] of {String, String}) do
      ov = ca_hosts_editor
      h = OverlayHarness.new(ov)
      ca_mnemonic(h, 'a')
      h.type("10.0.0.1 staging.acme.test")
      h.click(0, 0).should eq(:open) # driven through the shell's dispatch this time
      h.click(0, 0).should eq(:closed)
    end
  end

  it "matches what esc does from the same state, key for key" do
    # The invariant is not "click-away stays open", it is "click-away ≡ esc". Pinned by
    # running both against identical editors and comparing the state they leave behind.
    with_ca_hosts([{"a.test", "10.0.0.1"}]) do
      clicked = ca_hosts_editor
      keyed = ca_hosts_editor
      {clicked, keyed}.each do |ov|
        hh = OverlayHarness.new(ov)
        ca_mnemonic(hh, 'a')
        hh.type("10.0.0.2 b.test")
      end
      clicked.handle_click(OverlayHarness::DEFAULT_AREA, 0, 0)
      keyed.handle_key(Termisu::Event::Key.new(CA_ESC)).should eq(:stay)
      clicked.adding?.should eq(keyed.adding?)
      clicked.to_overrides.should eq(keyed.to_overrides)
    end
  end

  it "still dismisses an UNDRAWN card mid-edit rather than trapping the operator" do
    # Below the floor `overlay_box` returns nil and render prints "needs a larger window"
    # instead of a card. Keeping the modal open on a click there would leave nothing on
    # screen to click a second time.
    with_ca_hosts([] of {String, String}) do
      ov = ca_hosts_editor
      ov.add_start
      ov.handle_click(Rect.new(0, 0, 20, 6), 5, 3).should eq(:cancel)
    end
  end

  it "leaves the clean-list click-away a plain dismiss" do
    with_ca_hosts([] of {String, String}) do
      ov = ca_hosts_editor
      ov.handle_click(OverlayHarness::DEFAULT_AREA, 0, 0).should eq(:cancel)
    end
  end
end

describe "EnvOverlay — click-away with an open sub-mode" do
  it "cancels the add ROW and keeps the editor up, exactly like esc" do
    with_ca_env("$", [] of {String, String}) do
      ov = ca_env_editor
      h = OverlayHarness.new(ov)
      ca_mnemonic(h, 'a')
      h.type("HOST api.example.com")
      h.overlay.handle_click(h.area, 0, 0).should eq(:stay)
      ov.adding?.should be_false
      ov.to_config[1].should be_empty
      h.click(0, 0).should eq(:closed) # the next click, now on a clean list, dismisses
    end
  end

  it "cancels the PREFIX row too — the other sub-mode holds typed input as well" do
    with_ca_env("$", [] of {String, String}) do
      ov = ca_env_editor
      h = OverlayHarness.new(ov)
      ca_mnemonic(h, 'p')
      h.type("%%")
      ov.prefix_editing?.should be_true
      h.overlay.handle_click(h.area, 0, 0).should eq(:stay)
      ov.prefix_editing?.should be_false
      ov.to_config[0].should eq("$") # uncommitted, so the sigil is untouched
    end
  end

  it "still dismisses an UNDRAWN card mid-edit rather than trapping the operator" do
    with_ca_env("$", [] of {String, String}) do
      ov = ca_env_editor
      ov.add_start
      ov.handle_click(Rect.new(0, 0, 20, 6), 5, 3).should eq(:cancel)
    end
  end

  it "leaves the clean-list click-away a plain dismiss" do
    with_ca_env("$", [] of {String, String}) do
      ca_env_editor.handle_click(OverlayHarness::DEFAULT_AREA, 0, 0).should eq(:cancel)
    end
  end
end
