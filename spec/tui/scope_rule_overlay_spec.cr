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
      view.commit_scope_rule("exclude", "string", "/admin").should eq(:dup) # same triple, new add
    ensure
      store.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end
end
