require "./spec_helper"

# Cross-connection read-modify-write of the WHOLE-DOCUMENT settings rows.
#
# The note set, the session-slot list and the project env table are each ONE row in
# `settings` holding a whole JSON document, so every edit to any of them is a
# read-modify-write. Done as two statements — `load` … `set_setting` — the loser of a race
# commits a document it built BEFORE the winner's row landed, and the winner's rows are
# erased. Both callers see success, because both writes really did commit; what the second
# one committed was the first one's work, deleted.
#
# MEASURED with two `gori mcp` processes against one project, 100 `create_note` each:
#
#     AAA reported ok=100 err=0 / BBB reported ok=100 err=0
#     TOTAL STORED: 103
#
# and at 500 each, 501 of 1000 — every call `isError:false`. Re-reading immediately before
# the write (which `create_note` did) narrows the window; it cannot close it, because the
# window is between the two STATEMENTS.
#
# TWO STORE HANDLES on one file is the in-process shape of that: each `Store` owns its own
# writer fiber and its own SQLite connection, so an interleave between them is exactly an
# interleave between two processes. Each mutation round-trips through a channel, which is a
# scheduling point — so the fibers below really do interleave rather than run to completion
# one at a time.
private def with_shared_db(&)
  path = File.tempname("gori-doc-race", ".db")
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

# Run `work` against both handles at once and answer when both are done.
private def race(a : Gori::Store, b : Gori::Store, &work : Gori::Store, String ->)
  done = Channel(Exception?).new(2)
  spawn do
    begin
      work.call(a, "A")
      done.send(nil)
    rescue ex
      done.send(ex)
    end
  end
  spawn do
    begin
      work.call(b, "B")
      done.send(nil)
    rescue ex
      done.send(ex)
    end
  end
  2.times { (ex = done.receive) && raise ex }
end

describe "whole-document settings rows under concurrent writers" do
  describe "the note set" do
    it "keeps every note when two connections append at the same time" do
      with_shared_db do |a, b|
        n = 25
        ids = [] of Int64
        race(a, b) do |store, tag|
          n.times do |i|
            id = Gori::Notes.create(store, "#{tag}-#{i}")
            raise "create_note reported a busy store" unless id
            ids << id
          end
        end

        doc = Gori::Notes.load(a)
        doc.size.should eq(2 * n)
        doc.notes.count { |note| note.text.starts_with?("A-") }.should eq(n)
        doc.notes.count { |note| note.text.starts_with?("B-") }.should eq(n)
        # The id is minted from the set the TRANSACTION read, so two concurrent creates can
        # never mint the same one — which is what `entity_links` keys on.
        doc.notes.map(&.id).uniq.size.should eq(2 * n)
        ids.sort.should eq(doc.notes.map(&.id).sort)
      end
    end

    it "answers Missing for an id a peer deleted, rather than resurrecting it" do
      with_shared_db do |a, b|
        id = Gori::Notes.create(a, "shared").not_nil!
        Gori::Notes.delete(b, id).should eq(Gori::Notes::Write::Committed)
        # `a` still holds the note in any snapshot it took; the transaction reads the row that
        # is actually there, so the deterministic refusal is the honest answer and it is NOT
        # the retryable `Busy`.
        Gori::Notes.update(a, id, "edited").should eq(Gori::Notes::Write::Missing)
        Gori::Notes.load(a).size.should eq(0)
      end
    end

    it "merges a peer's notes into a whole-session save instead of overwriting them" do
      with_shared_db do |a, b|
        mine = Gori::Notes::NoteEntry.new(1_i64, "mine")
        Gori::Notes.save(a, [mine], Set(Int64).new, 1_i64, 2_i64).should_not be_nil
        peer = Gori::Notes.create(b, "peer").not_nil!
        merged = Gori::Notes.save(a, [Gori::Notes::NoteEntry.new(1_i64, "mine edited")],
          Set(Int64).new, 1_i64, 2_i64).not_nil!
        merged.notes.map(&.text).should contain("peer")
        merged.notes.map(&.text).should contain("mine edited")
        merged.notes.map(&.id).should contain(peer)
      end
    end
  end

  describe "the session-slot list" do
    it "keeps every slot when two connections add at the same time" do
      with_shared_db do |a, b|
        n = 15
        race(a, b) do |store, tag|
          slots = Gori::SessionSlots.load(store)
          n.times do |i|
            # Reload per add, exactly as the MCP surface does: the point is that even a
            # freshly-read list cannot make a two-statement write safe, and that the
            # transactional one does not need it to.
            slots.reload
            one = Gori::SessionSlot.new("#{tag}#{i}", set_headers: [{"X-Who", "#{tag}#{i}"}])
            raise "session add reported a busy store" unless slots.add(one)
          end
        end

        names = Gori::SessionSlots.load(a).slots.map(&.name)
        names.size.should eq(2 * n)
        names.count(&.starts_with?("A")).should eq(n)
        names.count(&.starts_with?("B")).should eq(n)
        # `with_one_baseline` still holds across the interleave: exactly one anchor.
        Gori::SessionSlots.load(a).slots.count(&.baseline?).should eq(1)
      end
    end

    it "removes one slot without taking a peer's additions with it" do
      with_shared_db do |a, b|
        sa = Gori::SessionSlots.load(a)
        sa.add(Gori::SessionSlot.new("admin")).should be_true
        sa.add(Gori::SessionSlot.new("doomed")).should be_true
        # `b` adds while `a` is holding a list that does not know about it…
        Gori::SessionSlots.load(b).add(Gori::SessionSlot.new("user")).should be_true
        sa.remove("doomed").should be_true
        Gori::SessionSlots.load(a).slots.map(&.name).sort.should eq(["admin", "user"])
      end
    end
  end

  describe "the project env table" do
    it "keeps every var when two connections set at the same time" do
      previous = Gori::Settings.project_env_vars
      begin
        with_shared_db do |a, b|
          n = 15
          race(a, b) do |store, tag|
            n.times do |i|
              raise "env set reported a busy store" unless Gori::Env.set_project_var(store, "#{tag}_#{i}", "v#{i}")
            end
          end

          vars = Gori::Env.parse_vars_json(a.setting(Gori::Env::PROJECT_VARS_KEY))
          vars.size.should eq(2 * n)
          vars.count { |(k, _)| k.starts_with?("A_") }.should eq(n)
          vars.count { |(k, _)| k.starts_with?("B_") }.should eq(n)
        end
      ensure
        Gori::Settings.project_env_vars = previous
      end
    end

    it "deletes one key without dropping a peer's" do
      previous = Gori::Settings.project_env_vars
      begin
        with_shared_db do |a, b|
          Gori::Env.set_project_var(a, "KEEP", "1").should be_true
          Gori::Env.set_project_var(b, "PEER", "2").should be_true
          Gori::Env.set_project_var(a, "DOOMED", "3").should be_true
          Gori::Env.delete_project_var(a, "DOOMED").should be_true
          Gori::Env.parse_vars_json(a.setting(Gori::Env::PROJECT_VARS_KEY))
            .map(&.[0]).sort.should eq(["KEEP", "PEER"])
        end
      ensure
        Gori::Settings.project_env_vars = previous
      end
    end
  end

  describe "Store#mutate_setting" do
    it "commits without writing when the block asks for no change" do
      with_shared_db do |a, _|
        a.set_setting("probe", "one").should be_true
        a.mutate_setting("probe") { |_| nil }.should be_true
        a.setting("probe").should eq("one")
      end
    end

    it "reports a raising block as a failed mutation and leaves the row alone" do
      # The block runs inside the writer's shared batch transaction, so an escape would roll
      # back unrelated captured flows with it. It is caught, the row is untouched, and the
      # caller is told the mutation did not happen.
      with_shared_db do |a, _|
        a.set_setting("probe", "one").should be_true
        a.mutate_setting("probe") { |_| raise "boom" }.should be_false
        a.setting("probe").should eq("one")
        # …and the store is still usable: nothing was retired.
        a.set_setting("probe", "two").should be_true
        a.setting("probe").should eq("two")
      end
    end

    it "sees the row a peer connection committed, not a snapshot from before it" do
      with_shared_db do |a, b|
        a.set_setting("probe", "a").should be_true
        b.set_setting("probe", "b").should be_true
        seen = nil.as(String?)
        a.mutate_setting("probe") do |current|
          seen = current
          "#{current}+a"
        end.should be_true
        seen.should eq("b")
        a.setting("probe").should eq("b+a")
      end
    end
  end
end
