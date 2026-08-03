require "../spec_helper"

# In-memory Store on a tempfile (mirrors spec/store/entity_links_spec.cr).
private def with_store(&)
  path = File.tempname("gori-links", ".db")
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

# Closing a Fuzzer/Miner sub-tab must take that session's `entity_links` rows with it, for the
# reason `delete_repeater` states: a link that outlives its session is a pointer with nothing
# to check it.
#
# Historically that was acute — `fuzz_sessions.id` / `miner_sessions.id` were plain
# `INTEGER PRIMARY KEY`, a tab close deletes at the TOP of the id space, so the next `^N` was
# handed the id that just went and a surviving link re-bound (`stale: false`, no `(gone)`) to
# an UNRELATED session, naming a target the operator never linked. Schema V10 gave both tables
# AUTOINCREMENT and seeded `sqlite_sequence` past every referenced id, so that reuse can no
# longer happen and a stray is now merely dead.
#
# The cascade is still the primary guarantee and is what these examples pin: V10 is the
# backstop for a stray created some way this cascade does not cover (an out-of-band delete, a
# future delete path written without it), not a replacement for it. See
# spec/store/link_ref_id_reuse_migration_spec.cr for the backstop's own coverage.
describe "workbench session deletes cascade entity_links" do
  it "drops a fuzz session's links so a reused rowid cannot re-point an issue's evidence" do
    with_store do |store|
      issue_id = store.insert_issue("xss", Gori::Store::Severity::High, "victim.test", nil)
      sid = store.insert_fuzz_session("https://victim.test", "GET /a HTTP/1.1\r\nHost: victim.test\r\n\r\n",
        false, nil, "{}", nil, 0, "victim sweep")
      store.add_link(Gori::Store::LinkOwnerKind::Issue, issue_id,
        Gori::Store::LinkRefKind::Fuzz, sid).should_not be_nil

      store.delete_fuzz_session(sid)
      store.get_fuzz_session(sid).should be_nil
      store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id).should be_empty

      # The next session against a different target. Before V10 the emptied table handed it
      # back the SAME rowid, and this example asserted that — the reuse was the whole reason
      # the cascade above mattered. V10 (AUTOINCREMENT + a seeded sqlite_sequence) removed that
      # premise, so the assertion is now its inverse. Both layers are kept and tested
      # separately on purpose: the cascade means no stray link survives a tab close, and V10
      # means a stray that survives some OTHER way — an out-of-band sqlite3 delete, a future
      # delete path written without the cascade — is merely dead rather than dangerous.
      # spec/store/link_ref_id_reuse_migration_spec.cr pins that second layer.
      reused = store.insert_fuzz_session("https://unrelated.test", "GET /b HTTP/1.1\r\nHost: unrelated.test\r\n\r\n",
        false, nil, "{}", nil, 0, "other target")
      reused.should_not eq(sid)

      resolved = Gori::Links.resolve_all(store,
        store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id))
      resolved.should be_empty
      resolved.map(&.url).should_not contain("https://unrelated.test")
      resolved.map(&.label).should_not contain("other target")
    end
  end

  it "drops a miner session's links so a reused rowid cannot re-point an issue's evidence" do
    with_store do |store|
      issue_id = store.insert_issue("idor", Gori::Store::Severity::Medium, "victim.test", nil)
      sid = store.insert_miner_session("https://victim.test",
        "GET /a HTTP/1.1\r\nHost: victim.test\r\n\r\n".to_slice, false, nil, "{}", nil, 0, "victim mine")
      store.add_link(Gori::Store::LinkOwnerKind::Issue, issue_id,
        Gori::Store::LinkRefKind::Miner, sid).should_not be_nil

      store.delete_miner_session(sid)
      store.get_miner_session(sid).should be_nil
      store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id).should be_empty

      # Was `eq(sid)` until V10 stopped rowid reuse — see the fuzz example above for why the
      # assertion inverted and why both layers are still worth keeping.
      reused = store.insert_miner_session("https://unrelated.test",
        "GET /b HTTP/1.1\r\nHost: unrelated.test\r\n\r\n".to_slice, false, nil, "{}", nil, 0, "other target")
      reused.should_not eq(sid)

      resolved = Gori::Links.resolve_all(store,
        store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id))
      resolved.should be_empty
      resolved.map(&.url).should_not contain("https://unrelated.test")
      resolved.map(&.label).should_not contain("other target")
    end
  end

  # `ref_id` is only meaningful together with `ref_kind` — session ids collide across kinds by
  # construction (every workbench table starts at 1), so a cascade that matched on `ref_id`
  # alone would delete a live flow/miner/repeater ref every time a fuzz tab closed.
  it "deletes only the closed session's own ref, not same-numbered refs of other kinds" do
    with_store do |store|
      issue_id = store.insert_issue("t", Gori::Store::Severity::Info, nil, nil)
      fuzz_id = store.insert_fuzz_session("https://f.test", "GET / HTTP/1.1\r\n\r\n", false, nil, "{}", nil, 0)
      miner_id = store.insert_miner_session("https://m.test", "GET / HTTP/1.1\r\n\r\n".to_slice,
        false, nil, "{}", nil, 0)
      {Gori::Store::LinkRefKind::Fuzz, Gori::Store::LinkRefKind::Miner,
       Gori::Store::LinkRefKind::Flow, Gori::Store::LinkRefKind::Repeater}.each do |kind|
        store.add_link(Gori::Store::LinkOwnerKind::Issue, issue_id, kind, fuzz_id)
      end
      fuzz_id.should eq(miner_id) # the collision the kind predicate has to survive

      store.delete_fuzz_session(fuzz_id)
      store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id).map(&.ref_kind).should eq(
        [Gori::Store::LinkRefKind::Miner, Gori::Store::LinkRefKind::Flow,
         Gori::Store::LinkRefKind::Repeater])

      store.delete_miner_session(miner_id)
      store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id).map(&.ref_kind).should eq(
        [Gori::Store::LinkRefKind::Flow, Gori::Store::LinkRefKind::Repeater])
    end
  end

  # A second owner's link to the same session is just as wrong once the id comes back, so the
  # cascade is keyed on the REF, not on one owner's list.
  it "drops the session's links for every owner, not just the first" do
    with_store do |store|
      issue_id = store.insert_issue("t", Gori::Store::Severity::Info, nil, nil)
      note_id = 7_i64 # notes carry their own stable ids (Notes::NoteEntry), no row to insert
      sid = store.insert_fuzz_session("https://f.test", "GET / HTTP/1.1\r\n\r\n", false, nil, "{}", nil, 0)
      store.add_link(Gori::Store::LinkOwnerKind::Issue, issue_id, Gori::Store::LinkRefKind::Fuzz, sid)
      store.add_link(Gori::Store::LinkOwnerKind::Note, note_id, Gori::Store::LinkRefKind::Fuzz, sid)

      store.delete_fuzz_session(sid)
      store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id).should be_empty
      store.list_links(Gori::Store::LinkOwnerKind::Note, note_id).should be_empty
    end
  end
end

# The sequencer delete takes the same cascade PRE-EMPTIVELY. Nothing can exercise it today —
# `LinkRefKind` has no `Sequencer` variant, so no link can name a sequencer session and the
# DELETE matches zero rows. What this example actually pins is that the delete still works and
# is harmless with the extra statement in it, so the line does not rot before the day it
# matters. If a `Sequencer` variant is ever added, replace this with the real fuzz/miner shape
# above — and give sequencer_sessions the V10 AUTOINCREMENT rebuild it was left out of.
describe "delete_sequencer_session" do
  it "deletes the session and is a no-op on entity_links, which cannot reference it" do
    with_store do |store|
      issue_id = store.insert_issue("tokens", Gori::Store::Severity::Low, "victim.test", nil)
      sid = store.insert_sequencer_session("https://victim.test",
        "GET /a HTTP/1.1\r\nHost: victim.test\r\n\r\n".to_slice, false, nil, "{}", nil, 0, "token run")
      # A link on the SAME numeric id but a kind that does exist — the cascade must not take
      # it, which is what makes the ref_kind predicate load-bearing rather than decorative.
      fuzz_sid = store.insert_fuzz_session("https://victim.test", "GET /a HTTP/1.1\r\n\r\n",
        false, nil, "{}", nil, 0, "sweep")
      fuzz_sid.should eq(sid) # both tables start at 1, so the ids collide by construction
      store.add_link(Gori::Store::LinkOwnerKind::Issue, issue_id,
        Gori::Store::LinkRefKind::Fuzz, fuzz_sid).should_not be_nil

      store.delete_sequencer_session(sid)
      store.get_sequencer_session(sid).should be_nil
      store.list_links(Gori::Store::LinkOwnerKind::Issue, issue_id).size.should eq(1)
    end
  end
end
