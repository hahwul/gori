require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def skey(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

private def stype(ov : ScopeRuleOverlay, s : String) : Nil
  s.each_char { |c| ov.handle_key(skey(Termisu::Input::Key::LowerA, c)) }
end

describe Gori::Tui::ScopeRuleOverlay do
  it "defaults to include / host and cycles kind and type with ←/→" do
    ov = ScopeRuleOverlay.adding
    ov.kind.should eq("include")
    ov.match_type.should eq("host")
    ov.editing?.should be_false

    ov.handle_key(skey(Termisu::Input::Key::Right)).should eq(:stay) # kind → exclude
    ov.kind.should eq("exclude")
    ov.handle_key(skey(Termisu::Input::Key::Down)).should eq(:stay)  # type row
    ov.handle_key(skey(Termisu::Input::Key::Right)).should eq(:stay) # host → string
    ov.match_type.should eq("string")
    ov.handle_key(skey(Termisu::Input::Key::Right)).should eq(:stay)
    ov.match_type.should eq("regex")
    ov.handle_key(skey(Termisu::Input::Key::Right)).should eq(:stay)
    ov.match_type.should eq("host")
  end

  it "seeds edit mode from an existing rule" do
    ov = ScopeRuleOverlay.editing(42_i64, "exclude", "regex", "api\\..*")
    ov.editing?.should be_true
    ov.edit_id.should eq(42_i64)
    ov.kind.should eq("exclude")
    ov.match_type.should eq("regex")
    ov.pattern.should eq("api\\..*")
  end

  it "types into the pattern field and commits on ↵" do
    ov = ScopeRuleOverlay.adding
    ov.handle_key(skey(Termisu::Input::Key::Down)) # type
    ov.handle_key(skey(Termisu::Input::Key::Down)) # pattern
    stype(ov, "acme.test")
    ov.pattern.should eq("acme.test")
    ov.handle_key(skey(Termisu::Input::Key::Enter)).should eq(:commit)
  end

  it "commits from the Save row and cancels on esc" do
    ov = ScopeRuleOverlay.adding
    ov.handle_key(skey(Termisu::Input::Key::Down))
    ov.handle_key(skey(Termisu::Input::Key::Down))
    stype(ov, "x.test")
    ov.handle_key(skey(Termisu::Input::Key::Down)) # Save
    ov.on_save_row?.should be_true
    ov.handle_key(skey(Termisu::Input::Key::Enter)).should eq(:commit)

    ov2 = ScopeRuleOverlay.adding
    ov2.handle_key(skey(Termisu::Input::Key::Escape)).should eq(:cancel)
  end

  it "renders without crashing and maps a click to a row" do
    ov = ScopeRuleOverlay.adding
    screen = Screen.new(MemoryBackend.new(80, 24))
    area = Rect.new(0, 0, 80, 24)
    ov.render(screen, area)
    box = ov.overlay_box(area).not_nil!
    ov.row_at(box, box.x + 3, box.y + 2).should eq(0) # kind row
    ov.row_at(box, box.x + 3, box.y + 5).should eq(3) # save row
  end

  # Listing a field in `text_fields` is the whole opt-in for caret-on-press, drag-select and
  # double-click-word (`Overlay#text_fields`), and a `TextField` can only answer a pointer
  # against the geometry its OWN `render` recorded. This form listed the field and then painted
  # it by hand, so every one of those gestures was a silent no-op: `handle_click` called
  # `click_text_field` per press and it could never hit, and `supports_drag?` reported true for
  # a field no drag could reach.
  it "places the caret where the pointer landed inside the pattern field" do
    ov = ScopeRuleOverlay.editing(1_i64, "include", "host", "acme.test")
    screen = Screen.new(MemoryBackend.new(80, 24))
    area = Rect.new(0, 0, 80, 24)
    box = ov.overlay_box(area).not_nil!
    ov.set_selected(2) # the pattern row
    ov.render(screen, area)

    field = ov.text_fields.first
    field.caret.should eq("acme.test".size) # seeded at the end
    # The value starts after "pattern:" plus one space — the same geometry `render` drew.
    vx = box.x + 3 + 9
    py = box.y + 2 + 2
    ov.handle_click(area, vx + 4, py).should eq(:stay)
    field.caret.should eq(4)

    # …and the drag/double-click halves of the same opt-in reach it too.
    ov.handle_drag(area, vx + 1, py)
    field.selection?.should be_true
    ov.handle_double_click(area, vx + 2, py).should eq(:stay)
  end

  # The press that FOCUSES the row lands on the frame drawn while the row was NOT selected,
  # and `TextField#render` draws an unfocused value from character 0 with no horizontal
  # window. Rebasing that click by `window_start` moved the caret by the whole scroll offset:
  # a 109-character pattern in a 58-column field, clicked on its third visible column, put the
  # caret at 54. `TextField` records WHICH of its two drawings the geometry came from.
  it "maps a click on the UNFOCUSED (unscrolled) pattern field to the column drawn there" do
    pattern = "^https://acme\\.test/(admin|internal|staging|preview)/.*[?&]debug=1&trace=on$"
    ov = ScopeRuleOverlay.editing(1_i64, "include", "regex", pattern)
    screen = Screen.new(MemoryBackend.new(80, 24))
    area = Rect.new(0, 0, 80, 24)
    box = ov.overlay_box(area).not_nil!
    ov.render(screen, area) # kind row is selected, so the pattern row draws unfocused

    field = ov.text_fields.first
    field.caret.should eq(pattern.size) # parked at the end, so a window WOULD scroll
    vx = box.x + 3 + 9
    py = box.y + 2 + 2
    ov.handle_click(area, vx + 2, py).should eq(:stay)
    field.caret.should eq(2) # the third drawn column, which is character 2 — not 2 + offset
  end
end

describe "ProjectView#commit_scope_rule" do
  it "adds and updates rules through the popup commit path" do
    path = File.tempname("gori-scope-popup", ".db")
    store = Gori::Store.open(path)
    begin
      scope = Gori::Scope.load(store)
      view = ProjectView.new(scope, Gori::HostOverrides.load(store))
      view.commit_scope_rule("include", "host", "acme.test").should eq(:ok)
      scope.rules.size.should eq(1)
      rule = view.selected_rule.not_nil!
      rule.pattern.should eq("acme.test")

      view.commit_scope_rule("exclude", "string", "/admin", rule.id).should eq(:ok)
      updated = view.selected_rule.not_nil!
      updated.kind.should eq("exclude")
      updated.match_type.should eq("string")
      updated.pattern.should eq("/admin")
      scope.rules.size.should eq(1)

      view.commit_scope_rule("include", "host", "").should eq(:empty)
      view.commit_scope_rule("include", "regex", "(bad").should eq(:invalid)
      view.commit_scope_rule("include", "host", "127.0.0.1:9091").should eq(:invalid)      # host+port can never match
      view.commit_scope_rule("include", "host", "https://acme.test/x").should eq(:invalid) # URL-shaped host: dead rule
      view.commit_scope_rule("exclude", "string", "/admin").should eq(:dup)                # same triple, new add

      # A no-op self-edit is NOT a duplicate — the popup re-committing the rule it was seeded
      # from must not be rejected by the pre-write dup check that splits :dup from :failed.
      view.commit_scope_rule("exclude", "string", "/admin", updated.id).should eq(:ok)
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end
end

# The HOST OVERRIDES inline row serves BOTH add and edit, but reported one `:ok` that the
# controller toasted as "host override added" even after an edit — and folded a store refusal
# into `:dup`, telling an operator who was already editing to "edit it (e)".
describe "ProjectView#ov_commit" do
  it "distinguishes an add from an edit, and a real duplicate from either" do
    path = File.tempname("gori-ov-commit", ".db")
    store = Gori::Store.open(path)
    begin
      overrides = Gori::HostOverrides.load(store)
      view = ProjectView.new(Gori::Scope.load(store), overrides)

      view.ov_add_start
      "10.0.0.1 staging.acme.test".each_char { |c| view.ov_input(c) }
      view.ov_commit.should eq(:ok)
      overrides.connect_address("staging.acme.test").should eq("10.0.0.1")

      # Re-committing the row the edit was SEEDED from is a no-op self-edit, not a duplicate —
      # the pre-write dup check that splits :dup from :failed has to skip the row being edited.
      view.ov_edit_start
      view.ov_commit.should eq(:updated)
      overrides.connect_address("staging.acme.test").should eq("10.0.0.1")

      view.ov_add_start
      "10.0.0.9 staging.acme.test".each_char { |c| view.ov_input(c) }
      view.ov_commit.should eq(:dup) # a DIFFERENT row already maps that host
      overrides.connect_address("staging.acme.test").should_not eq("10.0.0.9")

      view.ov_add_start
      "not-an-ip host.test".each_char { |c| view.ov_input(c) }
      view.ov_commit.should eq(:invalid)
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end
end
