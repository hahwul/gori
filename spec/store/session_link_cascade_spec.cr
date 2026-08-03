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
# reason `delete_repeater` states: `fuzz_sessions.id` / `miner_sessions.id` are plain
# `INTEGER PRIMARY KEY` (no AUTOINCREMENT), and a tab close deletes at the TOP of the id space,
# so the next `^N` is handed the id that just went. A surviving link then resolves — `stale:
# false`, no `(gone)` — to an UNRELATED session, and an issue's evidence names a target the
# operator never linked.
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

      # The emptied table hands the same rowid to the next session, against a different target.
      reused = store.insert_fuzz_session("https://unrelated.test", "GET /b HTTP/1.1\r\nHost: unrelated.test\r\n\r\n",
        false, nil, "{}", nil, 0, "other target")
      reused.should eq(sid) # the reuse this spec exists for — not an incidental id

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

      reused = store.insert_miner_session("https://unrelated.test",
        "GET /b HTTP/1.1\r\nHost: unrelated.test\r\n\r\n".to_slice, false, nil, "{}", nil, 0, "other target")
      reused.should eq(sid)

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
