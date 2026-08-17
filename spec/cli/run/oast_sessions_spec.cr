require "../../spec_helper"

# Test seams: both are private module methods, exposed here (test binary only) within the same
# namespace — the same trick spec/cli/run/oast_stop_spec.cr uses for `oast_wait_or_stop`.
module Gori::CLI::Run
  def self.spec_oast_subcommand_index(args : Array(String)) : Int32?
    oast_subcommand_index(args)
  end

  def self.spec_oast_stream_session(store : Gori::Store, bound : Gori::Oast::Sessions::Bound,
                                    http : Gori::Oast::Http, id : Int64, io : IO, err : IO,
                                    json : Bool = false) : Bool
    oast_stream_session(store, bound, http, id, 1, true, json, io, err)
  end
end

private def with_store(&)
  path = File.tempname("gori-cli-oast-sessions", ".db")
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

# A custom-http endpoint that answers one poll with one logged request. custom-http is the one
# provider whose `resume` is a no-op and whose poll is a plain GET, so a resume streams here
# without a single line of provider-specific scaffolding.
private class FakePollHttp < Gori::Oast::Http
  getter polls = 0

  def initialize(@body : String, @status : Int32 = 200)
  end

  def request(method : String, url : String,
              headers : Hash(String, String) = {} of String => String,
              body : String? = nil) : Gori::Oast::Http::Response
    @polls += 1
    Gori::Oast::Http::Response.new(@status, @body)
  end
end

private HIT_JSON = %([{"id":"hit-1","protocol":"http","method":"GET","ip":"203.0.113.7",) +
                   %("host":"oob.example","rawRequest":"GET /?oid=abc HTTP/1.1"}])

describe "gori run oast — persisted sessions" do
  describe "subcommand dispatch" do
    # `list` / `resume` / `release` read the PROJECT store, so they are dispatched before
    # strip_project_flags eats the --project/--db they need. That scan must skip a flag's
    # VALUE, or `--project list` would silently become the `list` subcommand.
    it "finds the first positional token, not a flag or a flag's value" do
      Gori::CLI::Run.spec_oast_subcommand_index(["resume", "7"]).should eq(0)
      Gori::CLI::Run.spec_oast_subcommand_index(["--project=lab", "list"]).should eq(1)
      Gori::CLI::Run.spec_oast_subcommand_index(["--project", "list", "resume", "7"]).should eq(2)
      Gori::CLI::Run.spec_oast_subcommand_index(["--db", "/tmp/x.db", "release", "3"]).should eq(2)
      Gori::CLI::Run.spec_oast_subcommand_index(["--json"]).should be_nil
      Gori::CLI::Run.spec_oast_subcommand_index([] of String).should be_nil
    end
  end

  describe "resume streaming" do
    it "persists what it polls into the session's own row and dedups a re-poll" do
      with_store do |store|
        id = store.insert_oast_session(nil, "custom-http", "https://oob.example/hits",
          "corr", "", nil, nil)
        store.flush
        bound = Gori::Oast::Sessions.bind(store, id, [] of Gori::Oast::ProviderConfig)
          .as(Gori::Oast::Sessions::Bound)
        http = FakePollHttp.new(HIT_JSON)
        io, err = IO::Memory.new, IO::Memory.new

        Gori::CLI::Run.spec_oast_stream_session(store, bound, http, id, io, err).should be_false
        store.flush
        store.oast_callback_count(id).should eq(1)
        # The same evidence table the TUI tab reads — a headless resume is not a side channel.
        store.oast_callbacks(id).first.provider_uid.should eq("hit-1")
        io.to_s.should contain("oob.example") # the fresh payload, then the hit line
        io.to_s.should contain("203.0.113.7")
        err.to_s.should contain("resumed session ##{id}")

        # A second run seeds its dedup set from the row, so a provider that replays its whole
        # buffer does not re-announce a callback already on file.
        io2 = IO::Memory.new
        Gori::CLI::Run.spec_oast_stream_session(store, bound, http, id, io2, IO::Memory.new)
        store.flush
        store.oast_callback_count(id).should eq(1)
        io2.to_s.should_not contain("203.0.113.7")
      end
    end

    it "stamps last_poll_at so the liveness signal sees a headless listener" do
      with_store do |store|
        id = store.insert_oast_session(nil, "custom-http", "https://oob.example/hits",
          "corr", "", nil, nil)
        store.flush
        store.get_oast_session(id).not_nil!.last_poll_at.should be_nil
        bound = Gori::Oast::Sessions.bind(store, id, [] of Gori::Oast::ProviderConfig)
          .as(Gori::Oast::Sessions::Bound)
        Gori::CLI::Run.spec_oast_stream_session(store, bound, FakePollHttp.new("[]"), id,
          IO::Memory.new, IO::Memory.new)
        store.flush
        store.get_oast_session(id).not_nil!.last_poll_at.should_not be_nil
      end
    end

    it "reports a failed --once poll so a scripted caller can tell it from 'no hits'" do
      with_store do |store|
        id = store.insert_oast_session(nil, "custom-http", "https://oob.example/hits",
          "corr", "", nil, nil)
        store.flush
        bound = Gori::Oast::Sessions.bind(store, id, [] of Gori::Oast::ProviderConfig)
          .as(Gori::Oast::Sessions::Bound)
        err = IO::Memory.new
        # A 500 is not an exception; a body that is not JSON is what a broken endpoint sends.
        failed = Gori::CLI::Run.spec_oast_stream_session(store, bound,
          FakePollHttp.new("<html>nope</html>", 200), id, IO::Memory.new, err)
        failed.should be_true
        err.to_s.should contain("poll error")
      end
    end

    it "emits the payload and each callback as JSON lines under --json" do
      with_store do |store|
        id = store.insert_oast_session(nil, "custom-http", "https://oob.example/hits",
          "corr", "", nil, nil)
        store.flush
        bound = Gori::Oast::Sessions.bind(store, id, [] of Gori::Oast::ProviderConfig)
          .as(Gori::Oast::Sessions::Bound)
        io = IO::Memory.new
        Gori::CLI::Run.spec_oast_stream_session(store, bound, FakePollHttp.new(HIT_JSON), id,
          io, IO::Memory.new, json: true)
        lines = io.to_s.lines.reject(&.empty?)
        first = JSON.parse(lines[0])
        first["session_id"].as_i64.should eq(id)
        first["payload_url"].as_s.should contain("oid=")
        # The same interaction shape MCP returns (Oast::Present), so the surfaces cannot drift.
        JSON.parse(lines[1])["destination"].as_s.should eq("oob.example")
        JSON.parse(lines[1])["provider"].as_s.should eq("custom-http")
      end
    end
  end
end
