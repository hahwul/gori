require "../spec_helper"

private def constraint_store(&)
  path = File.tempname("gori-constraint", ".db")
  db = DB.open("sqlite3:#{path}?journal_mode=wal&busy_timeout=5000")
  Gori::Store::Schema.migrate!(db)
  store = Gori::Store.new(db, nil)
  begin
    yield store
  ensure
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# NEVER a bare `store.close` in these examples. The bug they pin is a DEADLOCK, and a spec that
# reproduces it by hanging is worse than no spec at all — `crystal spec` block-buffers, so the
# run would sit there with no output and no indication of how far it got. Close on a fiber and
# select against a timeout, so a regression FAILS instead.
private def close_within(store : Gori::Store, span : Time::Span) : Bool
  done = Channel(Nil).new(1)
  spawn do
    store.close
    done.send(nil)
  end
  select
  when done.receive
    true
  when timeout(span)
    false
  end
end

# `UPDATE scope_rules` colliding with the table's UNIQUE(kind, match_type, pattern) is a
# REACHABLE write: `gori run project scope update` documents that very collision, and the TUI's
# dup pre-check reads a per-object snapshot, so a rule another instance added is invisible to it.
private def collide_scope_update(store : Gori::Store) : Bool
  store.add_scope_rule("include", "host", "a.test")
  store.add_scope_rule("include", "host", "peer.test")
  store.flush
  first = store.scope_rules.first[0]
  store.update_scope_rule(first, "include", "host", "peer.test")
end

describe "Gori::Store writer after a constraint violation" do
  it "reports the collision without failing the batch it was in" do
    constraint_store do |store|
      collide_scope_update(store).should be_false
      store.scope_rules.map { |(_, _, _, pattern)| pattern }.should eq(["a.test", "peer.test"])
      # ZERO, not one. The collision is now a no-op (`UPDATE OR IGNORE`) rather than a raise, so
      # the writer transaction commits: whatever captured flows the writer happened to group
      # into that batch are no longer discarded because an operator typed a duplicate pattern.
      store.write_failures.should eq(0)
      close_within(store, 20.seconds).should be_true
    end
  end

  it "closes instead of hanging forever" do
    constraint_store do |store|
      collide_scope_update(store)
      # sqlite holds a constraint error until the statement is FINALIZED, and the driver
      # finalizes its cached statements when the writer gives its connection back — i.e. during
      # `close`. That raise used to escape the writer fiber, so the `@done.send(nil)` it exits
      # with never ran and `close` parked on `@done.receive` for a sender that no longer existed.
      # Three things now stand between that and an operator: the write does not raise, the exit
      # send is in an `ensure`, and `close` refuses to re-close a half-torn-down pool.
      close_within(store, 20.seconds).should be_true
    end
  end

  it "keeps serving writes after the failed batch" do
    constraint_store do |store|
      collide_scope_update(store)
      # The batch rescue already protected the loop; this is the regression guard on it.
      store.add_scope_rule("include", "host", "after.test")
      store.flush
      store.scope_rules.size.should eq(3)
      close_within(store, 20.seconds).should be_true
    end
  end
end

describe Gori::Scope do
  it "reports a rule edit the store refused as NOT updated" do
    constraint_store do |store|
      store.add_scope_rule("include", "host", "mine.test")
      store.flush
      scope = Gori::Scope.load(store)
      target = scope.rules.first

      # A peer instance adds the triple this edit collides with. `Scope`'s own dup pre-check
      # reads the snapshot it loaded, so it cannot see this one — which is what lets the write
      # reach the table's UNIQUE constraint, where it is now ignored rather than raised.
      store.add_scope_rule("include", "host", "peer.test")
      store.flush

      scope.update(target.id, "include", "host", "peer.test").should be_false
      # And the rule really is unchanged, so the refusal is the truth.
      store.scope_rules.find { |(id, _, _, _)| id == target.id }
        .not_nil![3].should eq("mine.test")
      close_within(store, 20.seconds).should be_true
    end
  end

  it "still reports a genuine edit as updated" do
    constraint_store do |store|
      store.add_scope_rule("include", "host", "mine.test")
      store.flush
      scope = Gori::Scope.load(store)
      target = scope.rules.first
      scope.update(target.id, "exclude", "string", "/admin").should be_true
      scope.rules.first.pattern.should eq("/admin")
      close_within(store, 20.seconds).should be_true
    end
  end
end

# The OTHER way the writer can strand a caller: it dies mid-loop rather than surviving a batch.
# `writer_loop`'s rescue closes `@writes` so future senders take their `rescue
# Channel::ClosedError` path, then drains whatever is still buffered through `fail_reply` — a
# caller already parked on `reply.receive` for a queued op has no ClosedError to catch, so
# without that drain it blocks forever (under the proxy: a leaked ClientConn holding both
# sockets, per in-flight capture, with the flow left Pending).
#
# That drain is only as complete as `fail_reply`, and `fail_reply` is a `case` over the WriteOp
# subtypes — a subtype added without a branch is answered by nobody and silently reintroduces
# the hang. `IndexBatch` was exactly that: it had no branch, because until the drain existed
# `fail_reply` ran only from the per-batch rescue, where index replies are answered elsewhere.
#
# A runtime example cannot reach this — killing the writer OUTSIDE its per-batch rescue means
# raising from `await_op` or the connection release, neither of which a spec can inject without
# a seam that would itself be the change. So pin it at the source: every WriteOp that HAS a
# reply channel must appear in `fail_reply`.
describe "Store#fail_reply" do
  it "answers every WriteOp that has a reply channel" do
    src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "store.cr"))

    # Subtypes that declare `getter reply`. Sliced BETWEEN `struct … < WriteOp` headers rather
    # than matched with one regex per struct: a lazy `(?:.*?\n)*?` runs straight past its own
    # struct into the next one's `getter reply` and credits a fire-and-forget op with a reply
    # it does not have — which is how the first draft of this guard "proved" InsertH2Frame was
    # uncovered. InsertH2Frame having no reply is the point; deriving it keeps that honest.
    heads = [] of {String, Int32}
    src.scan(/struct (\w+) < WriteOp/) { |m| heads << {m[1], m.end} }
    with_reply = heads.each_with_index.compact_map do |(name, from), i|
      to = heads[i + 1]?.try(&.[](1)) || src.size
      src[from...to].includes?("getter reply :") ? name : nil
    end.to_a
    with_reply.should contain("IndexBatch")        # the one that was missing; guards the guard
    with_reply.should_not contain("InsertH2Frame") # the fire-and-forget op; guards the slicing
    with_reply.size.should be >= 8

    body = src[/private def fail_reply\(op : WriteOp\) : Nil.*?\n    end/m].not_nil!
    covered = body.scan(/when (\w+)/).map { |m| m[1] }
    (with_reply - covered).should be_empty
  end
end
