require "../../spec_helper"

# `gori run links` — the evidence pointers an Issue or Note carries. Both ENDS are
# validated before a link is filed: without that, `links add` would write an orphan row
# pointing at nothing and still report success, and `links list` on a typo'd id would
# print "no links on issue #99999" — which reads as "this issue has no evidence" rather
# than "there is no such issue".

private def with_store(&)
  path = File.tempname("gori-clilinks", ".db")
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

private def seed_flow(store : Gori::Store) : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "api.test", port: 443, method: "GET",
    target: "/x", http_version: "HTTP/1.1",
    head: "GET /x HTTP/1.1\r\nHost: api.test\r\n\r\n".to_slice))
end

# Private CLI glue — reopen the module for bare-call wrappers. (The `abort` branches of
# resolve_link_ends / parse_link_id call `exit`, so only their success paths run here.)
module Gori::CLI::Run
  def self.link_owner_exists_for_spec(store : Gori::Store, kind : Gori::Store::LinkOwnerKind, id : Int64) : Bool
    link_owner_exists?(store, kind, id)
  end

  def self.link_ref_exists_for_spec(store : Gori::Store, kind : Gori::Store::LinkRefKind, id : Int64) : Bool
    link_ref_exists?(store, kind, id)
  end

  def self.resolve_link_ends_for_spec(verb : String, owner_id : Int64?, ref_s : String?,
                                      ref_id : Int64?) : {Int64, Gori::Store::LinkRefKind, Int64}
    resolve_link_ends(verb, owner_id, ref_s, ref_id)
  end

  def self.parse_link_id_for_spec(v : String, flag : String) : Int64
    parse_link_id(v, flag)
  end
end

describe "gori run links — flag parsing" do
  it "parses --owner / --ref spellings and rejects anything else" do
    Gori::Store::LinkOwnerKind.parse("issue").should eq(Gori::Store::LinkOwnerKind::Issue)
    Gori::Store::LinkOwnerKind.parse("note").should eq(Gori::Store::LinkOwnerKind::Note)
    Gori::Store::LinkOwnerKind.parse("flow").should be_nil # a flow is a REF, never an owner

    Gori::Store::LinkRefKind.parse("flow").should eq(Gori::Store::LinkRefKind::Flow)
    Gori::Store::LinkRefKind.parse("repeater").should eq(Gori::Store::LinkRefKind::Repeater)
    Gori::Store::LinkRefKind.parse("fuzz").should eq(Gori::Store::LinkRefKind::Fuzz)
    Gori::Store::LinkRefKind.parse("miner").should eq(Gori::Store::LinkRefKind::Miner)
    Gori::Store::LinkRefKind.parse("issue").should be_nil # an issue is an OWNER, never a ref
  end

  it "returns the {owner id, ref kind, ref id} triple when all three are given" do
    Gori::CLI::Run.resolve_link_ends_for_spec("add", 4_i64, "repeater", 9_i64)
      .should eq({4_i64, Gori::Store::LinkRefKind::Repeater, 9_i64})
  end

  it "parses a plain integer id, including a large one" do
    Gori::CLI::Run.parse_link_id_for_spec("42", "--id").should eq(42_i64)
    Gori::CLI::Run.parse_link_id_for_spec("9007199254740993", "--ref-id").should eq(9_007_199_254_740_993_i64)
  end
end

describe "gori run links — end validation" do
  it "recognises an existing issue and rejects a missing one" do
    with_store do |store|
      id = store.insert_issue("finding", Gori::Store::Severity::Low, "api.test", nil)
      Gori::CLI::Run.link_owner_exists_for_spec(store, Gori::Store::LinkOwnerKind::Issue, id).should be_true
      Gori::CLI::Run.link_owner_exists_for_spec(store, Gori::Store::LinkOwnerKind::Issue, 99_999_i64).should be_false
    end
  end

  it "resolves a NOTE owner through the notes document, not a table row" do
    # Notes live as a JSON document under a settings key, so the note branch cannot use the
    # same "is there a row?" query the issue branch does.
    with_store do |store|
      store.set_setting("notes.docs",
        Gori::Notes.serialize(0, [Gori::Notes::NoteEntry.new(7_i64, "a")], 8_i64))
      nid = Gori::Notes.load(store).notes.first.id
      nid.should eq(7_i64)
      Gori::CLI::Run.link_owner_exists_for_spec(store, Gori::Store::LinkOwnerKind::Note, nid).should be_true
      Gori::CLI::Run.link_owner_exists_for_spec(store, Gori::Store::LinkOwnerKind::Note, nid + 1000).should be_false
    end
  end

  it "checks each ref kind against its own table" do
    with_store do |store|
      fid = seed_flow(store)
      rid = store.insert_repeater("https://api.test", "GET / HTTP/1.1\r\n\r\n".to_slice, false, true, nil, 0)

      Gori::CLI::Run.link_ref_exists_for_spec(store, Gori::Store::LinkRefKind::Flow, fid).should be_true
      Gori::CLI::Run.link_ref_exists_for_spec(store, Gori::Store::LinkRefKind::Repeater, rid).should be_true
      # A flow id is NOT a repeater id: the kinds must not fall through to a shared lookup.
      Gori::CLI::Run.link_ref_exists_for_spec(store, Gori::Store::LinkRefKind::Fuzz, fid).should be_false
      Gori::CLI::Run.link_ref_exists_for_spec(store, Gori::Store::LinkRefKind::Miner, rid).should be_false
      Gori::CLI::Run.link_ref_exists_for_spec(store, Gori::Store::LinkRefKind::Flow, 99_999_i64).should be_false
    end
  end
end

# The listing itself resolves through Gori::Links.resolve_all, whose ordering, per-element
# `stale?` flags and exact labels are already pinned strictly in spec/links_spec.cr — not
# duplicated here. What is CLI-specific is the validation above: `links list` refuses an
# unknown owner instead of printing "no links on issue #99999", which would read as "this
# issue has no evidence" rather than "there is no such issue".
