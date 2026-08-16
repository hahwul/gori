require "../spec_helper"
require "../support/memory_backend"
require "../../src/gori/tui/authorize_identity_overlay"
require "../../src/gori/tui/authorize_identities_overlay"

include Gori::Tui

private alias Identity = Gori::Authorize::Identity

private def okey(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

# Typing goes through the same path a terminal uses: a char-bearing key event.
private def otype(overlay, text : String) : Nil
  text.each_char { |c| overlay.handle_key(okey(Termisu::Input::Key::LowerA, c)) }
end

private def render(ov, w = 100, h = 30) : Nil
  ov.render(Screen.new(MemoryBackend.new(w, h)), Rect.new(0, 0, w, h))
end

describe AuthorizeIdentityOverlay do
  it "parses one Name: Value per line into set_headers" do
    ov = AuthorizeIdentityOverlay.new(
      Identity.new("admin", set_headers: [{"Cookie", "session=A"}, {"X-Role", "admin"}]))
    ov.set_headers.should eq([{"Cookie", "session=A"}, {"X-Role", "admin"}])
    ov.name.should eq("admin")
    render(ov)
  end

  it "round-trips remove_headers through the comma field" do
    ov = AuthorizeIdentityOverlay.new(Identity.new("anon", remove_headers: ["Cookie", "Authorization"]))
    ov.remove_headers.should eq(["Cookie", "Authorization"])
  end

  it "refuses a nameless identity and says so" do
    ov = AuthorizeIdentityOverlay.new
    ov.refusal.should eq("an identity needs a name")
    ov.build_identity.should be_nil
    ov.commit.should be_false # the shell keeps the card up
  end

  it "refuses a name another identity already uses" do
    ov = AuthorizeIdentityOverlay.new(Identity.new("admin"), nil, ["admin", "anon"])
    ov.refusal.not_nil!.should contain("already called")
    ov.build_identity.should be_nil
  end

  it "accepts a name that differs only by case from its own previous value when editing" do
    # index 0 is the one being edited, so its own name is not in `taken`
    ov = AuthorizeIdentityOverlay.new(Identity.new("admin"), 0, ["anon"])
    ov.refusal.should be_nil
    ov.build_identity.not_nil!.name.should eq("admin")
  end

  # A header line gori will not put on the wire is REFUSED and named — never dropped in
  # silence. A silently dropped Authorization line is how an authenticated run goes out
  # unauthenticated and reports nothing found.
  it "refuses a header line whose value carries CR/LF, naming the line" do
    ov = AuthorizeIdentityOverlay.new(Identity.new("x", set_headers: [{"Cookie", "a"}]))
    ov.set_selected(AuthorizeIdentityOverlay::EDITOR_ROW)
    ov.handle_key(okey(Termisu::Input::Key::Enter))
    otype(ov, "Bad Name: v")
    ov.rejected_lines.size.should eq(1)
    ov.refusal.not_nil!.should contain("RFC 7230 token")
    ov.build_identity.should be_nil
  end

  it "builds an identity once the form is valid" do
    ov = AuthorizeIdentityOverlay.new
    otype(ov, "low-priv")
    ov.set_selected(AuthorizeIdentityOverlay::EDITOR_ROW)
    otype(ov, "Cookie: session=USER")
    id = ov.build_identity.not_nil!
    id.name.should eq("low-priv")
    id.set_headers.should eq([{"Cookie", "session=USER"}])
    id.baseline?.should be_false
  end

  it "keeps the baseline flag it was opened with (the form never moves it)" do
    ov = AuthorizeIdentityOverlay.new(Identity.as_captured("base"), 0)
    ov.build_identity.not_nil!.baseline?.should be_true
  end

  it "cancels on esc" do
    AuthorizeIdentityOverlay.new.handle_key(okey(Termisu::Input::Key::Escape)).should eq(:cancel)
  end

  # The form was walkable only with ⇥: the editor swallowed every arrow, and Save answered
  # none — so a keyboard user could reach the last row and not get back out of it.
  describe "keyboard navigation" do
    it "walks every row with ↑/↓, editor included" do
      ov = AuthorizeIdentityOverlay.new(Identity.new("x", set_headers: [{"Cookie", "a"}]))
      ov.selected.should eq(AuthorizeIdentityOverlay::NAME_ROW)
      ov.handle_key(okey(Termisu::Input::Key::Down))
      ov.selected.should eq(AuthorizeIdentityOverlay::REMOVE_ROW)
      ov.handle_key(okey(Termisu::Input::Key::Down))
      ov.selected.should eq(AuthorizeIdentityOverlay::EDITOR_ROW)
      # a one-line buffer is at both edges, so the next ↓ leaves for Save
      ov.handle_key(okey(Termisu::Input::Key::Down))
      ov.selected.should eq(AuthorizeIdentityOverlay::SAVE_ROW)
    end

    it "walks back up out of the Save row" do
      ov = AuthorizeIdentityOverlay.new(Identity.new("x"))
      ov.set_selected(AuthorizeIdentityOverlay::SAVE_ROW)
      ov.handle_key(okey(Termisu::Input::Key::Up))
      ov.selected.should eq(AuthorizeIdentityOverlay::EDITOR_ROW)
    end

    it "keeps ↑/↓ inside a multi-line buffer until the caret reaches an edge" do
      ov = AuthorizeIdentityOverlay.new(
        Identity.new("x", set_headers: [{"A", "1"}, {"B", "2"}, {"C", "3"}]))
      ov.set_selected(AuthorizeIdentityOverlay::EDITOR_ROW)
      2.times { ov.handle_key(okey(Termisu::Input::Key::Down)) } # caret walks to the last line
      ov.selected.should eq(AuthorizeIdentityOverlay::EDITOR_ROW)
      ov.handle_key(okey(Termisu::Input::Key::Down)) # now at the bottom → leave
      ov.selected.should eq(AuthorizeIdentityOverlay::SAVE_ROW)
    end
  end

  # `remove:` gave no clue it wanted header NAMES. The pair of labels is what says so.
  it "labels the drop field as headers, alongside the set-headers caption" do
    b = MemoryBackend.new(100, 30)
    AuthorizeIdentityOverlay.new.render(Screen.new(b), Rect.new(0, 0, 100, 30))
    b.contains?("drop headers:").should be_true
    b.contains?("set headers").should be_true
    b.contains?("e.g. Cookie, Authorization").should be_true
  end
end

describe AuthorizeIdentitiesOverlay do
  private_ids = [
    Identity.as_captured("as-captured"),
    Identity.new("admin", set_headers: [{"Cookie", "session=SECRET"}]),
    Identity.new("anon", remove_headers: ["Cookie"]),
  ]

  it "arms an add and closes, leaving the opening to the shell" do
    ov = AuthorizeIdentitiesOverlay.new(private_ids)
    ov.handle_key(okey(Termisu::Input::Key::LowerA, 'a')).should eq(:cancel)
    ov.pending.not_nil!.index.should be_nil
  end

  it "arms an edit of the cursor row" do
    ov = AuthorizeIdentitiesOverlay.new(private_ids, 1)
    ov.handle_key(okey(Termisu::Input::Key::LowerE, 'e')).should eq(:cancel)
    ov.pending.not_nil!.index.should eq(1)
  end

  it "moves the baseline to exactly one identity" do
    ov = AuthorizeIdentitiesOverlay.new(private_ids, 2)
    saved = nil.as(Array(Identity)?)
    ov.on_change = ->(list : Array(Identity)) { saved = list; true }
    ov.handle_key(okey(Termisu::Input::Key::LowerB, 'b'))
    list = saved.not_nil!
    list.count(&.baseline?).should eq(1)
    list[2].baseline?.should be_true
    list[0].baseline?.should be_false
  end

  it "promotes a survivor when the baseline row is deleted" do
    ov = AuthorizeIdentitiesOverlay.new(private_ids, 0) # cursor on the baseline
    saved = nil.as(Array(Identity)?)
    ov.on_change = ->(list : Array(Identity)) { saved = list; true }
    ov.handle_key(okey(Termisu::Input::Key::LowerD, 'd'))
    list = saved.not_nil!
    list.size.should eq(2)
    list.count(&.baseline?).should eq(1) # never left without an anchor
  end

  it "refuses to delete the last identity" do
    ov = AuthorizeIdentitiesOverlay.new([Identity.as_captured])
    called = false
    ov.on_change = ->(_l : Array(Identity)) { called = true; true }
    ov.handle_key(okey(Termisu::Input::Key::LowerD, 'd'))
    ov.identities.size.should eq(1)
    called.should be_false
  end

  # The card is on screen for as long as the operator is reading it; a session cookie
  # painted there is a credential on screen.
  it "renders header names but never their values" do
    ov = AuthorizeIdentitiesOverlay.new(private_ids)
    backend = MemoryBackend.new(100, 30)
    ov.render(Screen.new(backend), Rect.new(0, 0, 100, 30))
    backend.contains?("admin").should be_true
    backend.contains?("sets Cookie").should be_true
    backend.contains?("SECRET").should be_false
  end

  it "closes on esc without arming anything" do
    ov = AuthorizeIdentitiesOverlay.new(private_ids)
    ov.handle_key(okey(Termisu::Input::Key::Escape)).should eq(:cancel)
    ov.pending.should be_nil
  end

  # The card listed what exists and said nothing about how to add to it — the actions were
  # only ever on the shell's hint strip, which is not where someone opening this looks.
  it "states its actions on the card, and names the baseline row in words" do
    b = MemoryBackend.new(100, 30)
    AuthorizeIdentitiesOverlay.new(private_ids).render(Screen.new(b), Rect.new(0, 0, 100, 30))
    b.contains?("a add").should be_true
    b.contains?("e edit").should be_true
    b.contains?("d delete").should be_true
    b.contains?("baseline").should be_true # the tag on the row, not a glyph legend
  end

  it "hands the row back to the actions once a transient note has been read" do
    ov = AuthorizeIdentitiesOverlay.new(private_ids, 2)
    ov.on_change = ->(_l : Array(Identity)) { true }
    ov.handle_key(okey(Termisu::Input::Key::LowerB, 'b')) # sets a note
    b = MemoryBackend.new(100, 30)
    ov.render(Screen.new(b), Rect.new(0, 0, 100, 30))
    b.contains?("is the baseline").should be_true
    b.contains?("a add").should be_false # the note has the row for now
  end

  it "tells an empty list how to start" do
    b = MemoryBackend.new(100, 30)
    AuthorizeIdentitiesOverlay.new([] of Identity).render(Screen.new(b), Rect.new(0, 0, 100, 30))
    b.contains?("a adds one").should be_true
  end
end
