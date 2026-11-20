require "../../spec_helper"
require "json"

# `gori run history --since ID` / `--before-id ID`: the cursors MCP `list_history` has, on the
# store query it uses, with its ordering — `--since` tails OLDEST first, `--before-id` pages
# older newest first — so a script continues from the last row's id either way.

private def history_stdout(args : Array(String)) : String
  stdout_captured { Gori::CLI::Run.dispatch(["history"] + args) }
end

private def with_flows(n : Int32, &)
  db = File.tempname("gori-history-cursor", ".db")
  store = Gori::Store.open(db)
  n.times do |i|
    store.insert_flow(Gori::Store::CapturedRequest.new(
      created_at: i.to_i64 + 1, scheme: "http", host: "c.test", port: 80, method: "GET",
      target: "/#{i}", http_version: "HTTP/1.1", head: "GET /#{i} HTTP/1.1\r\nHost: c.test\r\n\r\n".to_slice,
      source: Gori::FlowSource::Kind::Proxy))
  end
  store.close
  begin
    yield db
  ensure
    delete_db_files(db)
  end
end

# STDERR pointed at a file for the block, as `stdout_captured` does STDOUT.
private def stderr_captured(&) : String
  {% if flag?(:win32) %}
    pending!("STDERR is a handle on Windows, not an fd to dup")
  {% else %}
    path = File.tempname("gori-stderr", ".out")
    STDERR.flush
    saved = LibC.dup(STDERR.fd)
    File.open(path, "w") { |f| STDERR.reopen(f) }
    begin
      yield
    ensure
      STDERR.flush
      STDERR.reopen(IO::FileDescriptor.new(saved))
    end
    File.read(path).tap { File.delete?(path) }
  {% end %}
end

private def ids(json : String) : Array(Int64)
  JSON.parse(json).as_a.map(&.["id"].as_i64)
end

describe "gori run history --since / --before-id" do
  it "tails ids past --since oldest first, and the last id continues the tail" do
    with_flows(5) do |db|
      page = ids(history_stdout(["--since", "0", "-n", "2", "--json", "--db", db]))
      page.should eq([1_i64, 2_i64])
      page = ids(history_stdout(["--since", page.last.to_s, "-n", "2", "--json", "--db", db]))
      page.should eq([3_i64, 4_i64])
      ids(history_stdout(["--since", "5", "--json", "--db", db])).should be_empty
    end
  end

  it "pages older than --before-id newest first, and the last id continues the page" do
    with_flows(5) do |db|
      page = ids(history_stdout(["--before-id", "5", "-n", "2", "--json", "--db", db]))
      page.should eq([4_i64, 3_i64])
      ids(history_stdout(["--before-id", page.last.to_s, "--json", "--db", db])).should eq([2_i64, 1_i64])
    end
  end

  it "applies the cursor under a query too" do
    with_flows(5) do |db|
      ids(history_stdout(["-q", "host:c.test", "--since", "3", "--json", "--db", db])).should eq([4_i64, 5_i64])
    end
  end

  it "refuses the clashes MCP refuses" do
    Gori::CLI::Run.history_cursor_clash(1_i64, 2_i64, nil, false).not_nil!.should contain("only one of --since")
    Gori::CLI::Run.history_cursor_clash(1_i64, nil, Gori::Store::Rank::Slowest, false).not_nil!.should contain("--sort")
    Gori::CLI::Run.history_cursor_clash(nil, 1_i64, nil, true).not_nil!.should contain("--count")
    Gori::CLI::Run.history_cursor_clash(nil, nil, Gori::Store::Rank::Slowest, true).should be_nil
  end

  it "says how to continue a cut --since HAR, as the other formats do" do
    with_flows(3) do |db|
      har = %w[history --since 0 -n 2 --format har --db] << db
      # Pending flows: nothing is written to the HAR, and the cut is still said.
      stderr_captured { stdout_silenced { Gori::CLI::Run.dispatch(har) } }
        .should contain("Pass the last row's id back as --since for the next page.")
      store = Gori::Store.open(db)
      (1_i64..3_i64).each do |id|
        store.update_response(Gori::Store::CapturedResponse.new(flow_id: id, status: 200,
          head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, body: "ok".to_slice))
      end
      store.close
      err = stderr_captured { stdout_silenced { Gori::CLI::Run.dispatch(har) } }
      err.should contain("Pass the last row's id back as --since for the next page.")
      err.downcase.should_not contain("raise -n")
    end
  end

  it "says in -n's help that --since reads oldest first" do
    src = File.read(File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run", "history.cr"))
    src.should contain(%("Max rows, newest first (oldest first with --since) (default 50)"))
  end

  it "names the cursor in the truncation and empty-listing notes" do
    Gori::CLI::Run.history_truncation_note(true, 2, nil, "--since").not_nil!
      .should eq("showing the oldest 2 — more rows match. Pass the last row's id back as --since for the next page.")
    Gori::CLI::Run.empty_listing_note(nil, nil, false, cursor: "after id 9").should eq("no flows after id 9")
  end
end
