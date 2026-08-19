require "../spec_helper"

# Every example closes the store itself — that IS the lever for a refused commit — so the
# helper must not close it again (mirrors spec/commit_confirmation_spec.cr's header).
private def with_store(&)
  path = File.tempname("gori-session-rename", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# The three workbench sub-tab renames, the same class as the repeater metadata writes that
# spec/commit_confirmation_spec.cr pins: each was a narrow `UPDATE … SET name` declared `: Nil`
# and run through `exec_task`, whose Int64 reply is `last_insert_rowid` — meaningless for an
# UPDATE. So no caller could learn whether the batch committed, and the TUI's `apply_rename`
# (which sets the label on the view first) reported nothing at all: the chip kept showing the
# new name while the project still held the old one, until the session reloaded.
#
# All three together because they are one shape — `set_repeater_name` copied twice — and one
# lever: after `close` every write answers false rather than raising.
describe "workbench session renames report whether the write committed" do
  it "answers false once the store can no longer be written" do
    with_store do |store|
      fuzz = store.insert_fuzz_session("https://a.test", "GET /a HTTP/1.1\r\nHost: a.test\r\n\r\n",
        false, nil, "{}", nil, 0)
      # `insert_miner_session`/`insert_sequencer_session` bind `request` to a `BLOB NOT NULL`
      # column, so an EMPTY slice would roll the insert back and hand back 0 — a nil db_id, and
      # a rename that never reaches the store. Real bytes, and the id asserted, so a seeding
      # failure can never be mistaken for the refusal under test.
      req = "GET /m HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice
      miner = store.insert_miner_session("https://a.test", req, false, nil, "{}", nil, 0)
      seq = store.insert_sequencer_session("https://a.test", req, false, nil, "{}", nil, 0)
      fuzz.should be > 0
      miner.should be > 0
      seq.should be > 0

      store.set_fuzz_session_name(fuzz, "auth sweep").should be_true
      store.set_miner_session_name(miner, "login params").should be_true
      store.set_sequencer_session_name(seq, "session token").should be_true

      store.close # every write from here answers false

      store.set_fuzz_session_name(fuzz, "renamed").should be_false
      store.set_miner_session_name(miner, "renamed").should be_false
      store.set_sequencer_session_name(seq, "renamed").should be_false
    end
  end

  it "still persists the name it says it committed, without rewriting the request side" do
    # The answer has to be the store's, not a constant: a `true` that did not actually land
    # would be the same lie in the other direction.
    with_store do |store|
      req = "GET /m?q=1 HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice
      fuzz = store.insert_fuzz_session("https://a.test", "GET /?x=§1§ HTTP/1.1\r\n\r\n",
        false, nil, %({"mode":"sniper"}), nil, 0)
      miner = store.insert_miner_session("https://a.test", req, false, nil, "{}", nil, 0)
      seq = store.insert_sequencer_session("https://a.test", req, false, nil, "{}", nil, 0)

      store.set_fuzz_session_name(fuzz, "auth sweep").should be_true
      store.set_miner_session_name(miner, "login params").should be_true
      store.set_sequencer_session_name(seq, "session token").should be_true

      f = store.get_fuzz_session(fuzz).should_not be_nil
      f.name.should eq("auth sweep")
      f.template.should contain("§1§")
      m = store.get_miner_session(miner).should_not be_nil
      m.name.should eq("login params")
      m.request.should eq(req)
      s = store.get_sequencer_session(seq).should_not be_nil
      s.name.should eq("session token")
      s.request.should eq(req)

      # nil clears the custom label, and still answers.
      store.set_fuzz_session_name(fuzz, nil).should be_true
      store.get_fuzz_session(fuzz).not_nil!.name.should be_nil
    end
  end
end
