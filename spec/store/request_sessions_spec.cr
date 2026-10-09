require "../spec_helper"

# An `UPDATE … WHERE id = ?` on a row a peer gori deleted commits having matched nothing; a
# true there marked the tab clean although nothing persisted.
describe "workbench session saves report whether a row was written" do
  it "answers true for a live row and false once the row is gone" do
    with_store do |store|
      req = "GET /m HTTP/1.1\r\nHost: a.test\r\n\r\n".to_slice
      tpl = "GET /?x=§1§ HTTP/1.1\r\n\r\n"
      miner = store.insert_miner_session("https://a.test", req, false, nil, "{}", nil, 0)
      seq = store.insert_sequencer_session("https://a.test", req, false, nil, "{}", nil, 0)
      fuzz = store.insert_fuzz_session("https://a.test", tpl, false, nil, "{}", nil, 0)

      store.update_miner_session(miner, "https://a.test", req, false, nil, "{}", nil).should be_true
      store.update_sequencer_session(seq, "https://a.test", req, false, nil, "{}", nil).should be_true
      store.update_fuzz_session(fuzz, "https://a.test", tpl, false, nil, "{}").should be_true

      store.delete_miner_session(miner)
      store.delete_sequencer_session(seq)
      store.delete_fuzz_session(fuzz)

      store.update_miner_session(miner, "https://a.test", req, false, nil, "{}", nil).should be_false
      store.update_sequencer_session(seq, "https://a.test", req, false, nil, "{}", nil).should be_false
      store.update_fuzz_session(fuzz, "https://a.test", tpl, false, nil, "{}").should be_false
    end
  end
end
