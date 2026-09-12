require "../spec_helper"

# `Store#insert_issue` and the ONE invariant every surface that answers "what backs this
# issue" now depends on: an issue filed FROM a flow carries an `entity_links` row for that
# flow, written in the same transaction as the issue itself.
#
# The primary flow is the first RELATED row — in the TUI card, the Markdown report, the JSON
# export and MCP — so a `flow_id` with no link row is an issue whose own seed is missing from
# the list. `Links.issue_links` synthesises the row for the projects and hand-edits that can
# still produce one (spec/store/entity_links_spec.cr pins that half); nothing this store
# WRITES may need it, which is what this file pins.

private def flow(store, target = "/x") : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "acme.test", port: 443, method: "GET",
    target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
end

private def issue_links(store, id : Int64) : Array(Gori::Store::EntityLink)
  store.list_links(Gori::Store::LinkOwnerKind::Issue, id)
end

describe "Store#insert_issue" do
  it "links the primary flow in the same write" do
    with_store do |store|
      fid = flow(store)
      id = store.insert_issue("SQLi", Gori::Store::Severity::High, "acme.test", fid)
      id.should_not eq(0)
      links = issue_links(store, id)
      links.size.should eq(1)
      links[0].ref_kind.flow?.should be_true
      links[0].ref_id.should eq(fid)
      links[0].owner_id.should eq(id)
    end
  end

  # Every headless filer routes through this one method — `gori run issues create --flow`,
  # MCP `create_issue(flow_id:)`, the Probe analyzer's automatic filing, the TUI form — so
  # the guarantee holds for all of them without each having to remember the link.
  it "holds for a second issue on the same flow, and returns the ISSUE's id both times" do
    with_store do |store|
      fid = flow(store)
      a = store.insert_issue("first", Gori::Store::Severity::Low, "acme.test", fid)
      b = store.insert_issue("second", Gori::Store::Severity::Low, "acme.test", fid)
      b.should eq(a + 1)
      store.get_issue(a).not_nil!.title.should eq("first")
      store.get_issue(b).not_nil!.title.should eq("second")
      issue_links(store, a).map(&.ref_id).should eq([fid])
      issue_links(store, b).map(&.ref_id).should eq([fid])
    end
  end

  it "writes no link for a standalone issue" do
    with_store do |store|
      id = store.insert_issue("hand-written", Gori::Store::Severity::Info, nil, nil)
      issue_links(store, id).should be_empty
      store.get_issue(id).not_nil!.flow_id.should be_nil
    end
  end

  # The link is the seed, not a claim the flow exists: a caller that passes an id for a flow
  # the store never had (or one already pruned) still gets its issue, and `Links.resolve` is
  # what says `(gone)`. The CLI and MCP refuse such an id at their own boundary.
  it "still files the issue when the flow id names nothing" do
    with_store do |store|
      id = store.insert_issue("imported", Gori::Store::Severity::Low, "acme.test", 4242_i64)
      id.should_not eq(0)
      links = issue_links(store, id)
      links.size.should eq(1)
      Gori::Links.resolve(store, links[0]).stale?.should be_true
    end
  end

  # Every source file that writes an issue goes through `insert_issue` — there is no second
  # INSERT that could skip the link. A new one would have to be added here deliberately.
  it "is the only INSERT INTO issues in the source tree" do
    writers = [] of String
    Dir.glob(File.join(__DIR__, "..", "..", "src", "**", "*.cr")).each do |path|
      writers << path if File.read(path).includes?("INSERT INTO issues")
    end
    writers.map { |p| File.basename(p) }.should eq(["issues.cr"])
  end
end
