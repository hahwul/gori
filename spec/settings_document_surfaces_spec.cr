require "./spec_helper"
require "json"
require "../src/gori/tui/notes_view.cr"

# The SURFACES that read-modify-write a whole-document settings row.
#
# `spec/settings_document_race_spec.cr` pins the transactional API — `Store#mutate_setting`,
# `Notes.create/update/delete/save`, `Env.set_project_var/delete_project_var`. This file pins
# the other half, which is the half that was missing: that the surfaces an operator actually
# touches CALL it. A fixed helper nothing is wired to is dead code, and the loss it was
# written for keeps happening.
#
# MEASURED on this tree with two Store handles (two writer fibers, two connections — the
# in-process shape of two `gori` processes), 25 writes each:
#
#     surface                    before        after
#     MCP set_env_var            25/50 stored (all 50 reported ok)   50/50
#     gori run project env set   25/50                               50/50
#     gori run notes create      25/50, 25 unique ids                50/50, 50 ids
#     TUI NotesView#save         A 0/25, B 25/25                     25/25 and 25/25
#
# The CLI pair is pinned by source below rather than by a run: both commands print their
# result with a bare `puts` to the process STDOUT (there is no injectable IO), so driving 50
# of them would write 50 lines into the middle of the spec output. What is asserted there is
# the call — the behaviour under it is measured in settings_document_race_spec.
private def with_shared_db(&)
  path = File.tempname("gori-surface-race", ".db")
  a = Gori::Store.open(path, background_index: false)
  b = Gori::Store.open(path, background_index: false)
  begin
    yield a, b
  ensure
    a.close
    b.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def race(&work : Int32 ->)
  done = Channel(Exception?).new(2)
  2.times do |i|
    spawn do
      begin
        work.call(i)
        done.send(nil)
      rescue ex
        done.send(ex)
      end
    end
  end
  2.times { (ex = done.receive) && raise ex }
end

private def src_of(*parts : String) : String
  File.read(File.join(__DIR__, "..", "src", "gori", *parts))
end

describe "MCP env tools under a concurrent writer" do
  it "keeps a peer's var when two servers set different keys at once" do
    previous = Gori::Settings.project_env_vars
    begin
      with_shared_db do |a, b|
        # Two `Tools` on two handles = two `gori mcp` processes on one project. Each call
        # re-reads the table first (ENV_REFRESH_TOOLS) exactly as the server does; that is
        # the mitigation the old code relied on, and it is not enough — the gap is between
        # the two STATEMENTS, not between the read and the call.
        ta = Gori::MCP::Tools.new(a, allow_actions: true, verify_upstream: false)
        tb = Gori::MCP::Tools.new(b, allow_actions: true, verify_upstream: false)
        n = 15
        ok = 0
        race do |i|
          tools = i == 0 ? ta : tb
          tag = i == 0 ? "A" : "B"
          n.times do |k|
            r = tools.call("set_env_var", JSON.parse(%({"key":"#{tag}_#{k}","value":"v#{k}"})))
            ok += 1 unless r.is_error
          end
        end

        vars = Gori::Env.parse_vars_json(a.setting(Gori::Env::PROJECT_VARS_KEY))
        ok.should eq(2 * n) # every call reported success…
        vars.size.should eq(2 * n)
        vars.count { |(k, _)| k.starts_with?("A_") }.should eq(n)
        vars.count { |(k, _)| k.starts_with?("B_") }.should eq(n)
      end
    ensure
      Gori::Settings.project_env_vars = previous
    end
  end

  it "does not take a peer's new var down with a delete" do
    previous = Gori::Settings.project_env_vars
    begin
      with_shared_db do |a, b|
        ta = Gori::MCP::Tools.new(a, allow_actions: true, verify_upstream: false)
        tb = Gori::MCP::Tools.new(b, allow_actions: true, verify_upstream: false)
        n = 15
        race do |i|
          if i == 0
            # A churns its own key: the surface's delete path, running against a table the
            # peer is growing under it.
            n.times do |k|
              ta.call("set_env_var", JSON.parse(%({"key":"DOOMED_#{k}","value":"x"}))).is_error.should be_false
              ta.call("delete_env_var", JSON.parse(%({"key":"DOOMED_#{k}"}))).is_error.should be_false
            end
          else
            n.times { |k| tb.call("set_env_var", JSON.parse(%({"key":"KEEP_#{k}","value":"v"}))).is_error.should be_false }
          end
        end

        keys = Gori::Env.parse_vars_json(a.setting(Gori::Env::PROJECT_VARS_KEY)).map(&.[0])
        keys.count(&.starts_with?("KEEP_")).should eq(n)
        keys.count(&.starts_with?("DOOMED_")).should eq(0)
      end
    ensure
      Gori::Settings.project_env_vars = previous
    end
  end

  it "still answers NOT_FOUND for a key that is not there" do
    # The deterministic refusal survives the move to `delete_project_var`, which folds "no
    # such key" into the same `false` a busy store returns: the surface decides it against
    # the table it just re-read, so the two outcomes stay distinguishable to an agent (one
    # is worth retrying, the other never is).
    previous = Gori::Settings.project_env_vars
    begin
      with_shared_db do |a, _|
        tools = Gori::MCP::Tools.new(a, allow_actions: true, verify_upstream: false)
        r = tools.call("delete_env_var", JSON.parse(%({"key":"NOPE"})))
        r.is_error.should be_true
        r.text.should contain("no env var named")
      end
    ensure
      Gori::Settings.project_env_vars = previous
    end
  end
end

describe "TUI Notes tab under a concurrent writer" do
  it "keeps a peer session's notes when both save at once" do
    with_shared_db do |a, b|
      va = Gori::Tui::NotesView.new
      vb = Gori::Tui::NotesView.new
      va.reload(a)
      vb.reload(b)
      n = 15
      race do |i|
        view = i == 0 ? va : vb
        store = i == 0 ? a : b
        tag = i == 0 ? "A" : "B"
        n.times do |k|
          view.new_note
          "#{tag}-#{k}".each_char { |c| view.insert(c) }
          view.save(store).should be_true
        end
      end

      texts = Gori::Notes.load(a).texts
      texts.count(&.starts_with?("A-")).should eq(n)
      texts.count(&.starts_with?("B-")).should eq(n)
    end
  end

  it "reports a rolled-back save instead of dropping the note" do
    # A store that cannot write is the reachable stand-in for "the transaction did not
    # commit". `save` must answer false, keep `dirty?` up so a later exit path retries, and
    # leave the text in the buffer — the operator's only copy is on screen.
    path = File.tempname("gori-notes-ro", ".db")
    seed = Gori::Store.open(path, background_index: false)
    seed.close
    ro = Gori::Store.open(path, read_only: true, background_index: false)
    begin
      view = Gori::Tui::NotesView.new
      view.reload(ro)
      "keep me".each_char { |c| view.insert(c) }
      view.dirty?.should be_true
      view.save(ro).should be_false
      view.dirty?.should be_true
      view.current_text.should eq("keep me")
    ensure
      ro.close
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
    end
  end

  it "says so on the status line, and does not paint over the refusal" do
    # A SOURCE guard: reaching `NotesController` needs a live `Session` (CA, listener) and a
    # ~150-line Host double for one status string. What has to hold is that the refusal is
    # SAID — reporting nothing is what made a busy project look like it had saved — and that
    # a caller posting its own line right afterwards keeps quiet when the save was refused.
    src = File.read(File.join(__DIR__, "..", "src", "gori", "tui", "controllers", "notes_controller.cr"))
    body = src[Regex.new("    def save_notes : Bool.*?\n    end\n", Regex::Options::MULTILINE)]
    body.should contain("@notes.save(@host.session.store)")
    body.should contain("notes NOT saved")
    dup = src[Regex.new("    def notes_duplicate : Nil.*?\n    end\n", Regex::Options::MULTILINE)]
    dup.should contain("saved = save_notes")
    dup.should contain("if saved")
  end
end

describe "gori run — the CLI whole-document writers" do
  it "creates and deletes notes through the transactional Notes API" do
    src = src_of("cli", "run", "notes.cr")
    create = src[/private def self\.cmd_notes_create.*?\n      end\n/m]
    create.should contain("Notes.create(store, body)")
    delete = src[/private def self\.cmd_notes_delete.*?\n      end\n/m]
    delete.should contain("Notes.save(store,")
    # The whole point: neither writes the document row itself any more.
    src.should_not contain("set_setting(Notes::DOCS_KEY")
    # …and the delete still keeps the ACTIVE note by stable id rather than by position,
    # which is why it goes through `Notes.save` and not the shorter `Notes.delete`.
    delete.should contain("keep_id")
  end

  it "sets and deletes env vars through the transactional Env API" do
    src = src_of("cli", "run", "project.cr")
    set = src[/private def self\.cmd_env_set.*?\n      end\n/m]
    set.should contain("Env.set_project_var(store, key, val)")
    del = src[/private def self\.cmd_env_delete.*?\n      end\n/m]
    del.should contain("Env.delete_project_var(store, key)")
    # `save_project` writes the WHOLE array and is right only for the surface that owns the
    # whole array (the TUI's ENV pane) — no per-key CLI writer may call it.
    set.should_not contain("Env.save_project")
    del.should_not contain("Env.save_project")
    # The deterministic "no such key" refusal keeps its own exit, decided before the write.
    del.should contain("no env var named")
  end

  it "leaves the ENV pane's whole-array save alone" do
    # The axis is OWNERSHIP, not "transactions are better": `ProjectView`'s ENV pane edits
    # the entire table in place and persists what the operator sees, so `save_project` is
    # the correct call there and swapping it for a per-key mutator would make a deleted row
    # come back.
    src = src_of("tui", "controllers", "project_controller.cr")
    src.should contain("Env.save_project(@host.session.store, @project_view.env_vars)")
  end
end
