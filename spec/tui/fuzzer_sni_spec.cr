require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# `FuzzerView` has carried `@sni` since the tab shipped: it is persisted with the session,
# restored, compared by the cross-session reconcile, cloned by Duplicate and handed to
# `build_engine`. What it never had was an AFFORDANCE — no chord, no menu entry — so a fuzz
# session seeded from History (⇧I) could never set one and an https vhost sweep always
# presented the dialed IP. The single working route was Repeater ^S ▸ space ▸ Send to Fuzzer.
#
# These pin the affordance and, just as importantly, the complements: SNI unset must leave the
# card at its old height and `sni_override` nil, and every focus change must leave the sub-field.

private def sni_view(sni : String = "") : FuzzerView
  view = FuzzerView.new
  view.load_request("https://1.2.3.4", "GET / HTTP/1.1\r\nHost: vhost.test\r\n\r\n", false, sni)
  view.focus_pane(:target)
  view
end

private def type(view : FuzzerView, text : String) : Nil
  text.each_char { |c| view.target_insert(c) }
end

describe "FuzzerView SNI override" do
  it "^S opens the SNI field and typing lands there, not in the URL" do
    view = sni_view
    view.editing_sni?.should be_false
    view.sni_override.should be_nil

    view.toggle_sni_field
    view.editing_sni?.should be_true
    type(view, "vhost.test")

    view.sni_override.should eq("vhost.test")
    view.target.should eq("https://1.2.3.4") # the dialed host is untouched
    view.dirty?.should be_true
  end

  it "^S again (and exit_sni_field) returns to the URL keeping the value" do
    view = sni_view
    view.toggle_sni_field
    type(view, "a.test")
    view.toggle_sni_field
    view.editing_sni?.should be_false
    view.sni_override.should eq("a.test")
    type(view, "/x")
    view.target.should eq("https://1.2.3.4/x")
    view.sni_override.should eq("a.test")

    view.toggle_sni_field
    view.exit_sni_field
    view.editing_sni?.should be_false
  end

  # COMPLEMENT: unset SNI must not change anything the pane did before — the card keeps its
  # 3 rows, so the template pane does not lose a line to a field nobody asked for.
  it "leaves the TARGET card at its old height until an SNI exists" do
    plain = sni_view
    backend = MemoryBackend.new(100, 24)
    plain.render(Screen.new(backend), Rect.new(0, 0, 100, 24))
    backend.contains?("SNI ›").should be_false

    set = sni_view("vhost.test")
    b2 = MemoryBackend.new(100, 24)
    set.render(Screen.new(b2), Rect.new(0, 0, 100, 24))
    b2.contains?("SNI ›").should be_true
    b2.contains?("vhost.test").should be_true
  end

  # The Repeater's focus rule, mirrored: SNI editing is an explicit per-visit sub-mode, so
  # navigating away and back must not route URL keystrokes into @sni.
  it "drops back to the URL field on any focus change" do
    view = sni_view
    view.toggle_sni_field
    view.editing_sni?.should be_true
    view.pane_advance(1)
    view.editing_sni?.should be_false

    view.focus_pane(:target)
    view.toggle_sni_field
    view.focus_first
    view.editing_sni?.should be_false
  end

  it "backspace, caret movement and Home/End act on the field being edited" do
    view = sni_view
    view.toggle_sni_field
    type(view, "abc")
    view.target_backspace
    view.sni_override.should eq("ab")
    view.target_home
    view.target_insert('Z')
    view.sni_override.should eq("Zab")
    view.target_end
    view.target_insert('!')
    view.sni_override.should eq("Zab!")
    view.target.should eq("https://1.2.3.4") # never touched
  end

  # Persistence: the value has to survive the session round-trip a restart makes, and the
  # reconcile has to see the two as equal afterwards (otherwise a peer sync would clobber it).
  it "round-trips through the stored session record" do
    view = sni_view
    view.toggle_sni_field
    type(view, "vhost.test")
    rec = Gori::Store::FuzzSessionRecord.new(
      1_i64, view.target, view.template_text, view.http2?, view.sni_override,
      view.config_json, nil, 0, view.name)

    reopened = FuzzerView.new
    reopened.restore(rec)
    reopened.sni_override.should eq("vhost.test")
    reopened.editing_sni?.should be_false # a reopened tab is not mid-edit
    reopened.session_side_matches?(rec).should be_true
  end

  # A session seeded from HISTORY is the case the defect was about: it starts with no SNI and
  # must be able to acquire one.
  it "lets a History-seeded (evidence) session set an SNI" do
    view = FuzzerView.new
    row = Gori::Store::FlowRow.new(
      id: 1_i64, created_at: 0_i64, scheme: "https", method: "GET", host: "vhost.test",
      port: 443, target: "/x", status: 200, size: 0_i64, state: Gori::Store::FlowState::Complete)
    detail = Gori::Store::FlowDetail.new(row, "HTTP/1.1",
      "GET /x HTTP/1.1\r\nHost: vhost.test\r\n\r\n".to_slice, nil,
      "HTTP/1.1 200 OK\r\n\r\n".to_slice, nil)
    view.load(detail)
    view.evidence?.should be_true
    view.focus_pane(:target)
    view.toggle_sni_field
    type(view, "other.test")
    view.sni_override.should eq("other.test")
  end
end

describe "fuzz.toggle-sni verb" do
  it "is registered on ^S in the Fuzzer TARGET section" do
    v = Gori::Verbs.registry["fuzz.toggle-sni"]
    v.scope.should eq(Gori::Verb::Scope::Fuzzer)
    v.section.should eq(:target)
    v.chords.map(&.label).should eq(["ctrl-s"])
    # A Protocol… row, `P s` as on the Repeater: at level 1 `s` is fuzz.stop (#1274).
    Gori::Verbs.registry.menu_keys(v.id).should eq(['P', 's'])
    # The chord/mnemonic pair must not collide with anything the space menu can show
    # alongside it (COMMON ∪ :target) — `validate_menu_keys!` is the boot-time check.
    Gori::Verbs.registry.validate_menu_keys!
  end
end
