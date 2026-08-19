require "./spec_helper"

# `Bindings#add`/`#update` returned nil (= success) whatever the store answered, so MCP reported
# `updated: true` for an extract rule that never changed and the TUI form closed on a rule that
# was never saved. Worse for `update`: it ran its RENAME side effect — dropping the in-memory
# value observed under the old name — for a rename the store had refused.
private def bindings_store(&)
  path = File.tempname("gori-bindings-refusal", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close rescue nil
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

describe Gori::Bindings do
  it "reports a refused insert instead of claiming the rule was added" do
    bindings_store do |store|
      bindings = Gori::Bindings.load(store)
      bindings.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil # the happy path
      store.flush

      store.close # every write from here answers "dropped"
      bindings.add("OTHER", "", Gori::ExtractKind::Cookie, "other")
        .should eq(Gori::Bindings::STORE_REFUSED)
    end
  end

  # The other cause of the same refusal: not a closed store but a STALE in-memory list, so
  # `validate`'s "one name, one writer" (pinned in bindings_spec.cr) cannot see the collision
  # and only the store's answer can refuse. `insert_extract_rule` returns 0 there because it
  # reads `changes()`; `last_insert_rowid()` alone is not reset by an ignored `INSERT OR
  # IGNORE`, so it answered this connection's PREVIOUS insert — the peer's row below — and the
  # operator's discarded rule was reported saved.
  it "reports a refused insert when a peer already took the name, list still stale" do
    bindings_store do |store|
      # Loaded while the table was empty: this is the operator's table as it stood before its
      # next `PRAGMA data_version` poll, so it never saw the peer's row.
      bindings = Gori::Bindings.load(store)
      store.insert_extract_rule("TOKEN", "", Gori::ExtractKind::Cookie, "peer-sid")
      store.flush

      bindings.add("TOKEN", "", Gori::ExtractKind::Cookie, "mine")
        .should eq(Gori::Bindings::STORE_REFUSED)

      # And the refusal is the truth: the peer's descriptor is what `$TOKEN` still expands.
      store.extract_rules.find { |r| r.name == "TOKEN" }.not_nil!.selector.should eq("peer-sid")
    end
  end

  it "reports a refused update and leaves the rule exactly as it was" do
    path = File.tempname("gori-bindings-refusal2", ".db")
    begin
      store = Gori::Store.open(path)
      bindings = Gori::Bindings.load(store)
      bindings.add("SESSION", "", Gori::ExtractKind::Cookie, "sid").should be_nil
      store.flush
      id = store.extract_rules.find { |r| r.name == "SESSION" }.not_nil!.id

      store.close # every write from here answers "did not commit"
      bindings.update(id, "RENAMED", "", Gori::ExtractKind::Cookie, "sid")
        .should eq(Gori::Bindings::STORE_REFUSED)

      # The refusal is the truth: reopened, the rule still carries its old descriptor. The
      # `return` also sits BEFORE the rename side effect, so the in-memory value observed under
      # the old name is not dropped for a rename that never happened.
      reopened = Gori::Store.open(path)
      begin
        reopened.extract_rules.map(&.name).should eq(["SESSION"])
      ensure
        reopened.close
      end
    ensure
      File.delete?(path)
      File.delete?("#{path}-wal")
      File.delete?("#{path}-shm")
      File.delete?("#{path}.open.lock")
    end
  end
end
