require "../spec_helper"
require "../../src/gori/authorize/identity"

private alias Identity = Gori::Authorize::Identity

private def with_store(&)
  path = File.tempname("gori-authorize", ".db")
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

# The identities are project state, and the project's `settings` table is where they live —
# the same key/value table `env.vars` uses, so no schema migration is involved.
describe "Authorize identity persistence" do
  it "writes to the project settings table and reads back the same set" do
    ids = [
      Identity.as_captured("as-captured"),
      Identity.new("low-priv", set_headers: [{"Cookie", "session=USER"}]),
      Identity.new("anonymous", remove_headers: ["Cookie", "Authorization"]),
    ]
    with_store do |store|
      store.set_setting(Gori::Store::AUTHORIZE_IDENTITIES_KEY, Gori::Authorize.serialize(ids)).should be_true
      back = Gori::Authorize.parse_json(store.setting(Gori::Store::AUTHORIZE_IDENTITIES_KEY))
      back.map(&.name).should eq(["as-captured", "low-priv", "anonymous"])
      back[1].set_headers.should eq([{"Cookie", "session=USER"}])
      back[2].remove_headers.should eq(["Cookie", "Authorization"])
      back.count(&.baseline?).should eq(1)
    end
  end

  it "reads back nothing when the key was never written" do
    with_store do |store|
      Gori::Authorize.parse_json(store.setting(Gori::Store::AUTHORIZE_IDENTITIES_KEY)).should be_empty
    end
  end

  # `set_setting` answers false on a closing/busy store rather than raising. The caller has to
  # look: an identity that silently failed to persist is gone at the next restart, with the
  # operator having watched it appear in the list.
  it "reports a failed write instead of raising" do
    with_store do |store|
      store.close
      store.set_setting(Gori::Store::AUTHORIZE_IDENTITIES_KEY, "[]").should be_false
    end
  end
end
