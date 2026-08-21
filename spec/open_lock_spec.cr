require "./spec_helper"
require "file_utils"

private def with_project(&)
  root = File.tempname("gori-open-lock")
  begin
    registry = Gori::ProjectRegistry.new(root)
    yield registry, registry.create("target")
  ensure
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# `ProjectRegistry#delete` refused a project whose CAPTURE lock was held, and its comment names
# the harm: rm_rf unlinks the db under a live writer, which then keeps "successfully" writing into
# a pathless inode. But capturing is not the only way to be writing — an MCP server takes no
# capture lock and writes issues, notes, repeaters and fuzz history all the same.
describe Gori::OpenLock do
  it "refuses to delete a project that another store has open" do
    with_project do |registry, project|
      store = Gori::Store.open(project.db_path)
      begin
        Gori::OpenLock.in_use?(project.db_path).should be_true
        expect_raises(Gori::Error, /open in another gori instance/) { registry.delete(project) }
        Dir.exists?(project.dir).should be_true # not wiped out from under the writer
      ensure
        store.close
      end

      # Closed ⇒ the lock is gone and the delete proceeds, so this is a retryable refusal and not
      # a project that can never be removed.
      Gori::OpenLock.in_use?(project.db_path).should be_false
      registry.delete(project)
      Dir.exists?(project.dir).should be_false
    end
  end

  it "stays in use until the LAST holder closes" do
    with_project do |registry, project|
      a = Gori::Store.open(project.db_path)
      b = Gori::Store.open(project.db_path) # a second instance: shared holders coexist
      begin
        Gori::OpenLock.in_use?(project.db_path).should be_true
        a.close
        Gori::OpenLock.in_use?(project.db_path).should be_true # b still has it
      ensure
        b.close
      end
      Gori::OpenLock.in_use?(project.db_path).should be_false
      registry.delete(project)
      Dir.exists?(project.dir).should be_false
    end
  end

  it "keys on the database, so another db in the same directory does not block it" do
    with_project do |registry, project|
      sibling = File.join(project.dir, "other.db")
      store = Gori::Store.open(sibling)
      begin
        # Two databases sharing a directory are two databases — the same rule the capture lock
        # and the capture-status marker are keyed by.
        Gori::OpenLock.in_use?(project.db_path).should be_false
        Gori::OpenLock.in_use?(sibling).should be_true
      ensure
        store.close
      end
    end
  end

  it "does not call a leftover lock file 'in use'" do
    with_project do |_registry, project|
      Gori::Store.open(project.db_path).close
      # The file persists after release, exactly like the capture lock's. Only a FAILED flock
      # means somebody is there.
      File.exists?(Gori::OpenLock.path(project.db_path)).should be_true
      Gori::OpenLock.in_use?(project.db_path).should be_false
    end
  end

  it "answers false for a database nobody ever opened, and for :memory:" do
    with_project do |_registry, project|
      Gori::OpenLock.in_use?(File.join(project.dir, "never-opened.db")).should be_false
      Gori::OpenLock.in_use?(":memory:").should be_false
      # An in-memory store must open normally with no lock to take.
      store = Gori::Store.open(":memory:")
      store.count.should eq(0)
      store.close
    end
  end

  it "still refuses on the capture lock, with its own message" do
    with_project do |registry, project|
      # The two guards are separate questions and keep separate wording, so an operator is told
      # which one to act on.
      lock = Gori::CaptureLock.try(project.dir).not_nil!
      begin
        expect_raises(Gori::Error, /stop its capture first/) { registry.delete(project) }
      ensure
        lock.close
      end
      registry.delete(project)
      Dir.exists?(project.dir).should be_false
    end
  end
end

# The review found three ways this could fail closed instead of open. Each is pinned here.
describe "Gori::OpenLock resilience" do
  it "yields no lock instead of raising when the lock file cannot be opened" do
    with_project do |_registry, project|
      # A DIRECTORY where the lock file goes: `File.open(…, "a")` raises EISDIR while the
      # database itself opens fine. The same shape as an unwritable project dir or a lock file
      # owned by a teammate — `File::Error`, which is neither `DB::Error` nor `Gori::Error`, so
      # letting it escape would kill `gori mcp` before the handshake and backtrace `gori run
      # capture`. The class promises to degrade to "no lock", never to "no store".
      File.delete?(Gori::OpenLock.path(project.db_path)) # `create` already materialized it
      Dir.mkdir_p(Gori::OpenLock.path(project.db_path))
      Gori::OpenLock.try_shared(project.db_path).should be_nil
      store = Gori::Store.open(project.db_path)
      begin
        store.count.should eq(0) # the store opened regardless
      ensure
        store.close
      end
    end
  end

  it "keys on the canonicalized database, so two spellings share one lock" do
    real = File.tempname("gori-lock-real")
    link = File.tempname("gori-lock-link")
    Dir.mkdir_p(File.join(real, "projects", "api"))
    File.symlink(real, link)
    begin
      through_link = File.join(link, "projects", "api", Gori::Project::DB_FILE)
      through_real = File.join(real, "projects", "api", Gori::Project::DB_FILE)
      # `--db` takes what the operator typed; the registry builds its path from `$GORI_HOME` as
      # it was given. One database must not end up with two lock files, or a probe against the
      # wrong one answers "nobody has it open" and the rm_rf proceeds under a live writer.
      Gori::OpenLock.path(through_link).should eq(Gori::OpenLock.path(through_real))
      store = Gori::Store.open(through_link)
      begin
        Gori::OpenLock.in_use?(through_real).should be_true
      ensure
        store.close
      end
      Gori::OpenLock.in_use?(through_real).should be_false
    ensure
      File.delete?(link)
      FileUtils.rm_rf(real)
    end
  end

  it "refuses instead of announcing nothing while an exclusive guard is held, and works once it is not" do
    with_project do |_registry, project|
      Gori::Store.open(project.db_path).close # materialize the lock file
      guard = Gori::OpenLock.try_exclusive(project.db_path).not_nil!
      begin
        # The ONE case that does not degrade to "no lock". An exclusive holder is always a
        # destructive operation (a compact's strip + VACUUM, a delete's rm_rf), so returning nil
        # here — as this used to — meant the caller opened a database being rewritten or unlinked
        # with nothing announcing it to the process doing that. Bounded, so it is a sentence and
        # not a hang: CONTENTION_BUDGET of short sleeps, then raise.
        expect_raises(Gori::Error, /compacting or deleting/) do
          Gori::OpenLock.try_shared(project.db_path)
        end
      ensure
        guard.close
      end
      shared = Gori::OpenLock.try_shared(project.db_path)
      shared.should_not be_nil
      shared.not_nil!.close
    end
  end

  it "does not open a store unannounced while an exclusive guard is held" do
    with_project do |_registry, project|
      Gori::Store.open(project.db_path).close # materialize the lock file
      guard = Gori::OpenLock.try_exclusive(project.db_path).not_nil!
      # The refusal must not cost a descriptor per attempt: the raise path is the one place
      # `try_shared` leaves its own lock-file handle behind if it forgets to close it, and
      # nothing about the exception itself would show that.
      baseline = Dir.children("/dev/fd").size
      begin
        # What the bug looked like from here: `Store.open` returned a live, writable Store
        # while `Compact`/`delete` held the exclusive lock, so the compact's VACUUM (or the
        # delete's rm_rf) ran under a writer it could not see. Reproduced as an INSERT that
        # committed "successfully" into a directory that no longer existed.
        # Two, not more: each refusal waits out the whole CONTENTION_BUDGET, and the spec
        # exercises the shipped budget rather than a parameterized short one.
        2.times do
          ex = expect_raises(Gori::Error) { Gori::Store.open(project.db_path) }
          # Names the path as the CALLER spelled it, which is what `Project#open_failure_reason`
          # keys on to pass a message through to the picker verbatim.
          ex.message.to_s.should contain(project.db_path)
        end
        (Dir.children("/dev/fd").size - baseline).should be < 2
      ensure
        guard.close
      end
      # Released ⇒ the open succeeds and announces itself, so this is a retryable refusal and
      # not a project that can no longer be opened.
      store = Gori::Store.open(project.db_path)
      begin
        Gori::OpenLock.in_use?(project.db_path).should be_true
        store.count.should eq(0)
      ensure
        store.close
      end
    end
  end
end
