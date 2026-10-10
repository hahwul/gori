require "../spec_helper"

describe Gori::Oast::SeenWindow do
  it "answers true once per key and keeps only the newest cap" do
    w = Gori::Oast::SeenWindow(String).new(2)
    w.add?("a").should be_true
    w.add?("a").should be_false
    w.add?("b").should be_true
    w.add?("c").should be_true # evicts "a", the oldest
    w.size.should eq(2)
    w.includes?("a").should be_false
    w.add?("b").should be_false
    w.add?("a").should be_true # older than the window: shown again (the store dedups the row)
  end
end

describe Gori::Oast::Sessions do
  it "seeds a resumed listener's window with the newest uids on file" do
    with_store do |store|
      id = store.insert_oast_session(nil, "interactsh", "https://oast.pro", "corr", "sec", nil, nil)
      store.flush
      (Gori::Oast::DEDUP_WINDOW + 1).times do |n|
        store.insert_oast_callback(id, "uid-#{n}", "http", "GET", nil, "f", "r".to_slice, nil, n.to_i64)
      end
      store.flush
      seen = Gori::Oast::Sessions.seen_uids(store, id)
      seen.size.should eq(Gori::Oast::DEDUP_WINDOW)
      seen.includes?("uid-0").should be_false
      seen.includes?("uid-#{Gori::Oast::DEDUP_WINDOW}").should be_true
    end
  end
end
