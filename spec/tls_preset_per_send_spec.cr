require "./spec_helper"
require "./support/memory_backend"

include Gori::Tui

private alias R = Gori::Repeater

# #844 — the per-send TLS fingerprint override, at the surfaces that carry it: the plan
# builders that validate it, the store column that survives a reopen, and the Repeater tab
# that lets an operator pick one.
#
# `spec/proxy/outbound_tls_override_spec.cr` owns the policy/cache-key half. This file owns
# the question "does an operator's choice actually reach a send, and come back when the tab
# is reopened".

private def ungated : Gori::Outbound
  Gori::Outbound.waived(nil, Gori::Outbound::Reason::NoProject)
end

private RAW = "GET /a HTTP/1.1\r\nHost: t.test\r\n\r\n"

private def with_store(&)
  path = File.tempname("gori-tls-preset", ".db")
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

describe "per-send TLS fingerprint — Repeater plan" do
  it "carries a valid preset onto the plan and its sender" do
    plan = R::Plan.build(R::PlanOptions.new([RAW.to_slice],
      target: "https://t.test", tls_preset: "chrome"), ungated)
    plan.tls_preset.should eq("chrome")
    plan.sender.tls_preset.should eq("chrome")
  end

  it "normalises the name so one intent is one policy" do
    plan = R::Plan.build(R::PlanOptions.new([RAW.to_slice],
      target: "https://t.test", tls_preset: "  CHROME "), ungated)
    plan.tls_preset.should eq("chrome")
  end

  it "means no override when absent or blank" do
    [nil, "", "  "].each do |none|
      plan = R::Plan.build(R::PlanOptions.new([RAW.to_slice],
        target: "https://t.test", tls_preset: none), ungated)
      plan.tls_preset.should be_nil
      plan.sender.tls_preset.should be_nil
    end
  end

  # Refused, never applied-as-nothing: an unknown name shapes no ClientHello, so the send
  # would go out with gori's bare OpenSSL hello while every surface reported the browser the
  # operator asked for. The refusal has to happen BEFORE the dial, and it has to carry the
  # machine-readable reason each surface words for itself.
  it "refuses an unknown preset before anything dials" do
    ex = expect_raises(R::PlanError) do
      R::Plan.build(R::PlanOptions.new([RAW.to_slice],
        target: "https://t.test", tls_preset: "chromee"), ungated)
    end
    ex.reason.should eq(R::PlanError::Reason::TlsPreset)
    ex.detail.should eq("chromee")
    ex.message.not_nil!.should contain("chrome")
  end

  # The field-native h2 path is a second builder inside the same file, and every argument
  # that only reached one of the two has been a parity gap before.
  it "carries the preset on the field-native h2 path too" do
    plan = R::Plan.build(R::PlanOptions.new(
      h2_fields: [{":method", "GET"}, {":path", "/fn"}],
      target: "https://t.test", http2: true, tls_preset: "safari"), ungated)
    plan.tls_preset.should eq("safari")
    plan.sender.tls_preset.should eq("safari")
  end
end

private def fuzz_options(preset : String?) : Gori::Fuzz::PlanOptions
  cfg = Gori::Fuzz::Config.new
  cfg.tls_preset = preset
  Gori::Fuzz::PlanOptions.new("GET /§a§ HTTP/1.1\r\nHost: t.test\r\n\r\n",
    target: "https://t.test", config: cfg,
    sources: [Gori::Fuzz::InlineList.new(%w[x])] of Gori::Fuzz::PayloadSource)
end

describe "per-send TLS fingerprint — fuzz plan" do
  it "carries the run's preset onto the plan and its sender" do
    plan = Gori::Fuzz::Plan.build(fuzz_options("firefox"), ungated)
    plan.tls_preset.should eq("firefox")
  end

  it "refuses an unknown preset before the first request" do
    ex = expect_raises(Gori::Fuzz::PlanError) do
      Gori::Fuzz::Plan.build(fuzz_options("safarii"), ungated)
    end
    ex.reason.should eq(Gori::Fuzz::PlanError::Reason::TlsPreset)
    ex.detail.should eq("safarii")
  end

  it "means no override when absent" do
    Gori::Fuzz::Plan.build(fuzz_options(nil), ungated).tls_preset.should be_nil
  end
end

# "A reopened Repeater tab sends the fingerprint it was saved with" — the acceptance
# criterion, exercised through the column rather than asserted about it.
describe "per-send TLS fingerprint — persistence (Schema V22)" do
  it "round-trips through insert → load on every read path" do
    with_store do |store|
      id = store.insert_repeater("https://a.test", RAW.to_slice, false, true, nil, 0,
        tls_preset: "chrome")
      id.should be > 0
      store.repeaters.first.tls_preset.should eq("chrome")
      store.repeaters_meta.first.tls_preset.should eq("chrome")
      store.repeaters_mcp.first.tls_preset.should eq("chrome")
      store.get_repeater(id).not_nil!.tls_preset.should eq("chrome")
      store.get_repeater_full(id).not_nil!.tls_preset.should eq("chrome")
    end
  end

  it "updates and clears" do
    with_store do |store|
      id = store.insert_repeater("https://a.test", RAW.to_slice, false, true, nil, 0)
      store.get_repeater(id).not_nil!.tls_preset.should be_nil # every pre-#844 row reads this way

      store.update_repeater(id, "https://a.test", RAW.to_slice, false, true, tls_preset: "curl")
      store.get_repeater(id).not_nil!.tls_preset.should eq("curl")

      store.update_repeater(id, "https://a.test", RAW.to_slice, false, true, tls_preset: nil)
      store.get_repeater(id).not_nil!.tls_preset.should be_nil
    end
  end
end

describe "per-send TLS fingerprint — Repeater tab" do
  it "cycles none → every preset → none" do
    view = RepeaterView.new
    view.restore("https://t.test", RAW, false, true)
    view.tls_preset.should be_nil
    Gori::Settings::TLS_PRESET_NAMES.each do |name|
      view.cycle_tls_preset.should eq(name)
      view.tls_preset.should eq(name)
    end
    # …and all the way round, so "no override" is reachable with the same one key rather
    # than needing a second binding nobody would find.
    view.cycle_tls_preset.should be_nil
    view.tls_preset.should be_nil
  end

  it "marks the tab dirty so the save-on-leave path persists the choice" do
    view = RepeaterView.new
    view.restore("https://t.test", RAW, false, true)
    view.dirty?.should be_false
    view.cycle_tls_preset
    view.dirty?.should be_true
  end

  it "restores what it was saved with, folding a blank row to no override" do
    view = RepeaterView.new
    view.restore("https://t.test", RAW, false, true, tls_preset: "firefox")
    view.tls_preset.should eq("firefox")

    # A row written as "" (a peer, an older writer, an MCP clear) is "no override", not an
    # empty preset name — otherwise the reconcile poll would see the row as changed forever.
    blank = RepeaterView.new
    blank.restore("https://t.test", RAW, false, true, tls_preset: "")
    blank.tls_preset.should be_nil
  end

  it "converges a peer's change and stops re-applying an equivalent row" do
    view = RepeaterView.new
    view.restore("https://t.test", RAW, false, true)
    view.request_side_matches?("https://t.test", RAW, false, true, nil,
      tls_preset: "chrome").should be_false
    view.apply_peer_request("https://t.test", RAW, false, true, tls_preset: "chrome")
    view.tls_preset.should eq("chrome")
    view.request_side_matches?("https://t.test", RAW, false, true, nil,
      tls_preset: "chrome").should be_true
    # "" and nil are one value here, exactly as they are for SNI — without the fold, every
    # poll against a row holding "" would re-apply and slam the caret.
    view.apply_peer_request("https://t.test", RAW, false, true, tls_preset: "")
    view.request_side_matches?("https://t.test", RAW, false, true, nil,
      tls_preset: nil).should be_true
  end

  # An http:// target has no ClientHello to shape. The value is KEPT (the operator set it,
  # P4) but reported as not live, which is what the muted chip says.
  it "reports the override as inert on a plaintext target without discarding it" do
    view = RepeaterView.new
    view.restore("http://t.test", RAW, false, true, tls_preset: "chrome")
    view.tls_preset.should eq("chrome")
    view.tls_preset_live?.should be_false

    https = RepeaterView.new
    https.restore("https://t.test", RAW, false, true, tls_preset: "chrome")
    https.tls_preset_live?.should be_true
  end

  it "carries the fingerprint into a duplicated tab" do
    src = RepeaterView.new
    src.restore("https://t.test", RAW, false, true, tls_preset: "safari")
    clone = RepeaterView.new
    clone.duplicate_from(src)
    clone.tls_preset.should eq("safari")
  end
end
