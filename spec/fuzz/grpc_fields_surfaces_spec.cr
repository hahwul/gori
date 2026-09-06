require "../spec_helper"
require "../support/demo_descriptor"
require "socket"
require "file_utils"

# #843's last acceptance criterion — "TUI, `gori run fuzz` and MCP all reach it" — and the
# shape that makes it true: the work lives in `Fuzz::Plan.build`, the surface-independent
# chokepoint (P1), and each surface's whole job is to put its own input into `PlanOptions`.
#
# So this file pins the SEAM rather than the engine. The engine half is
# spec/fuzz/grpc_fields_spec.cr, which is byte-level; what can rot here is a surface quietly
# not passing the argument — the exact failure `PlanOptions#processors` records for the TUI,
# where a comment claimed "all three surfaces share one list" in the commit that made it false.

private alias Fuzz = Gori::Fuzz
private alias Protobuf = Gori::Protobuf
private alias Grpc = Gori::Proxy::H2::Grpc

private def demo_request_frame : Bytes
  Grpc.frame(false, Protobuf::Encoder.length_delimited(1_u32, "hahwul".to_slice))
end

private def grpc_template(host : String) : String
  frame = demo_request_frame
  io = IO::Memory.new
  io.write("POST /demo.Users/GetUser HTTP/1.1\r\nHost: #{host}\r\n" \
           "content-type: application/grpc\r\ncontent-length: #{frame.size}\r\n\r\n".to_slice)
  io.write(frame)
  String.new(io.to_slice)
end

private def with_demo_schema(&)
  dir = File.tempname("gori-surf-protos")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "demo.desc"), Base64.decode(DEMO_DESC_B64))
  Protobuf::Schemas.apply(dir)
  yield
ensure
  Protobuf::Schemas.clear
  FileUtils.rm_rf(dir) if dir
end

private def with_surf_store(&)
  path = File.tempname("gori-grpcfuzz", ".db")
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

# An origin that answers 200 to anything and records every request body it was given — the
# only honest place to check what a field position put on the wire.
private class RecordingOrigin
  getter port : Int32
  getter connections : Int32 = 0
  getter bodies = [] of Bytes

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    spawn { accept_loop }
  end

  def close : Nil
    @server.close
  end

  private def accept_loop : Nil
    while conn = @server.accept?
      @connections += 1
      # `spawn serve(conn)`, NOT `spawn { serve(conn) }`: the block form closes over the loop
      # variable, so a second accept re-points it and both fibers serve the SAME socket while
      # the first connection sits unread until its client times out.
      spawn serve(conn)
    end
  rescue
  end

  private def serve(conn : TCPSocket) : Nil
    len = 0
    while line = conn.gets(chomp: true)
      break if line.empty?
      idx = line.index(':')
      next unless idx && line[0, idx].strip.downcase == "content-length"
      len = line[(idx + 1)..].strip.to_i? || 0
    end
    body = Bytes.new(len)
    conn.read_fully(body) if len > 0
    @bodies << body
    conn << "HTTP/1.1 200 OK\r\ncontent-type: application/grpc\r\ngrpc-status: 0\r\n" \
            "Content-Length: 0\r\nConnection: close\r\n\r\n"
    conn.flush
  rescue
  ensure
    conn.close rescue nil
  end
end

# The rendered request's single gRPC message payload — what the origin would parse.
private def rendered_message(bytes : Bytes) : Bytes
  body = Fuzz::GrpcVerdict.body(bytes).not_nil!
  msgs, residual = Grpc.scan(body)
  residual.should eq(0)
  msgs.size.should eq(1)
  msgs[0].data
end

private def call_raw(tools, name, args : String) : {String, Bool}
  r = tools.call(name, JSON.parse(args))
  {r.text, r.is_error}
end

private def call_json(tools, name, args : String) : JSON::Any
  text, err = call_raw(tools, name, args)
  fail "tool #{name} errored: #{text}" if err
  JSON.parse(text)
end

describe "gRPC field positions reach every fuzz surface" do
  # The guard for the NEXT surface, and for the next edit of these three. Each of them owns a
  # `PlanOptions.new` call and a one-line job: hand its own input over. A surface that stops
  # doing it still compiles, still runs and still reports a clean sweep — of the request the
  # operator did not ask for.
  it "every fuzz surface passes grpc_fields into PlanOptions" do
    root = File.expand_path(File.join(__DIR__, "..", ".."))
    {
      "src/gori/cli/run/fuzz.cr"    => "--field",
      "src/gori/mcp/tools/fuzz.cr"  => "fuzz_grpc_fields",
      "src/gori/tui/fuzzer_view.cr" => "grpc_field_specs",
    }.each do |rel, own_input|
      src = File.read(File.join(root, rel))
      src.should contain("grpc_fields:")
      src.should contain(own_input)
    end
  end

  describe "MCP fuzz_start{fields}" do
    it "declares `fields`, so the unknown-argument gate lets it through" do
      with_surf_store do |store|
        tools = tools_for(store)
        text, err = call_raw(tools, "fuzz_start", %({"template":"x","fields":["role"]}))
        err.should be_true                          # no template/target — refused for THAT
        text.should_not contain("unknown argument") # …not for the argument's name
      end
    end

    it "refuses a named field with no descriptor set — before anything dials" do
      origin = RecordingOrigin.new
      begin
        Protobuf::Schemas.clear
        with_surf_store do |store|
          tools = tools_for(store)
          args = {
            "template"       => grpc_template("127.0.0.1"),
            "url"            => "http://127.0.0.1:#{origin.port}",
            "fields"         => ["name"],
            "payloads"       => [{"list" => ["a"]}],
            "allow_unscoped" => true,
          }.to_json
          text, err = call_raw(tools, "fuzz_start", args)
          err.should be_true
          text.should contain("no descriptor set resolves")
          text.should contain("/demo.Users/GetUser")
        end
        # A refusal that arrives after the SYN is not a refusal.
        origin.connections.should eq(0)
      ensure
        origin.close
      end
    end

    it "sweeps the field, and the octets on the wire are the declaration's" do
      origin = RecordingOrigin.new
      begin
        with_surf_store do |store|
          tools = tools_for(store)
          # AFTER the bind: `Tools.new` publishes the project's own (empty) schema registry,
          # so a descriptor set applied before it would be replaced by the bind.
          with_demo_schema do
            args = {
              "template"       => grpc_template("127.0.0.1"),
              "url"            => "http://127.0.0.1:#{origin.port}",
              "fields"         => ["name"],
              "payloads"       => [{"list" => ["zz", "a-much-longer-value"]}],
              "allow_unscoped" => true,
            }.to_json
            start = call_json(tools, "fuzz_start", args)
            start["total"].as_i.should eq(2)
            # WHICH declaration the named field bound to. The CLI prints this once up front and
            # an agent needs it for the same reason: it passed a NAME, and a stale descriptor
            # set resolving it to a different field is otherwise undetectable.
            g = start["grpc"]
            g["method"].as_s.should eq("/demo.Users/GetUser")
            g["message"].as_s.should eq("demo.GetUserRequest")
            g["fields"][0]["spec"].as_s.should eq("name")
            g["fields"][0]["number"].as_i.should eq(1)
            g["fields"][0]["type"].as_s.should eq("string")
            job_id = start["job_id"].as_s
            done = false
            last = JSON::Any.new(nil)
            200.times do
              sleep 0.02.seconds
              last = call_json(tools, "fuzz_status", %({"job_id":#{job_id.to_json}}))
              break done = true unless last["status"].as_s == "running"
            end
            fail "fuzz job never finished: #{last.to_json}" unless done
            call_json(tools, "fuzz_status",
              %({"job_id":#{job_id.to_json}}))["errors"].as_i.should eq(0)
          end
        end
        origin.bodies.size.should eq(2)
        origin.bodies.each do |body|
          msgs, residual = Grpc.scan(body)
          residual.should eq(0) # the 5-byte prefix follows the message it now describes
          msgs.size.should eq(1)
        end
        # By CONTENT, not by arrival order: the sweep runs both variations concurrently, so
        # which connection the origin accepts first is not the generator's emit order.
        seen = origin.bodies.map { |b| Grpc.scan(b)[0][0].data.to_a }.to_set
        ["zz", "a-much-longer-value"].each do |v|
          seen.should contain(Protobuf::Encoder.length_delimited(1_u32, v.to_slice).to_a)
        end
      ensure
        origin.close
      end
    end

    it "leaves the echo alone for a sweep that named no field" do
      with_surf_store do |store|
        tools = tools_for(store)
        text, err = call_raw(tools, "fuzz_start", %({"template":"x"}))
        err.should be_true # no payloads/target — but the point is the key, not the refusal
        text.should_not contain(%("grpc"))
      end
    end
  end

  describe "the TUI Fuzzer tab" do
    it "round-trips the ADVANCED row and persists it with the session" do
      view = Gori::Tui::FuzzerView.new
      view.load_request("https://api.test", grpc_template("api.test"), false, "")
      view.advanced_snapshot.grpc_fields.should eq("")

      snap = view.advanced_snapshot
      view.apply_advanced(Gori::Tui::AdvancedSnapshot.new(
        conc: snap.conc, rate: snap.rate, timeout: snap.timeout, retries: snap.retries,
        max_requests: snap.max_requests, race: snap.race,
        follow: snap.follow, calibrate: snap.calibrate, keep_alive: snap.keep_alive,
        update_cl: snap.update_cl, reframe_grpc: snap.reframe_grpc,
        m_status: snap.m_status, m_size: snap.m_size, m_words: snap.m_words, m_regex: snap.m_regex,
        f_status: snap.f_status, f_size: snap.f_size, f_words: snap.f_words, f_regex: snap.f_regex,
        grpc_fields: "name, profile.age"))
      view.advanced_snapshot.grpc_fields.should eq("name, profile.age")

      # …and it survives the tab's own serialization, as the raw text the operator typed: a
      # spec that no longer resolves (the descriptor set moved) has to come back as itself.
      restored = Gori::Tui::FuzzerView.new
      restored.restore(Gori::Store::FuzzSessionRecord.new(
        1_i64, "https://api.test", grpc_template("api.test"), false, nil,
        view.config_json, nil, 0))
      restored.advanced_snapshot.grpc_fields.should eq("name, profile.age")
    end

    it "counts a field-only run in the Run row instead of reporting zero requests" do
      view = Gori::Tui::FuzzerView.new
      view.load_request("https://api.test", grpc_template("api.test"), false, "")
      view.apply_set(nil, Gori::Tui::SetSpec.new(:list, "a,b,c"))
      view.position_count.should eq(0)     # no §…§ markers at all
      view.run_request_count.should be_nil # …and with no field either, nothing to count
      snap = view.advanced_snapshot
      view.apply_advanced(Gori::Tui::AdvancedSnapshot.new(
        conc: snap.conc, rate: snap.rate, timeout: snap.timeout, retries: snap.retries,
        max_requests: snap.max_requests, race: snap.race,
        follow: snap.follow, calibrate: snap.calibrate, keep_alive: snap.keep_alive,
        update_cl: snap.update_cl, reframe_grpc: snap.reframe_grpc,
        m_status: snap.m_status, m_size: snap.m_size, m_words: snap.m_words, m_regex: snap.m_regex,
        f_status: snap.f_status, f_size: snap.f_size, f_words: snap.f_words, f_regex: snap.f_regex,
        grpc_fields: "name"))
      view.run_request_count.should eq(3_i64)
    end

    # `result_request` reconstructs a row whose bytes were not retained (`keep_bodies: :matched`
    # and the row missed — the TUI default, so EVERY non-matching row). A field payload lives
    # inside a re-encoded protobuf message, not in a `§…§` span, so handing the base `Template` a
    # vector that long appends it past the last segment: the capture with the payload dangling
    # off the end of the frame, under a Content-Length resynced to cover it — shown in the detail
    # pane and seeded into Repeater by "Send to Repeater".
    it "reconstructs a non-retained row through the composite, not the base template" do
      with_demo_schema do
        view = Gori::Tui::FuzzerView.new
        view.load_request("https://api.test", grpc_template("api.test"), false, "")
        view.apply_set(nil, Gori::Tui::SetSpec.new(:list, "zz"))
        snap = view.advanced_snapshot
        view.apply_advanced(Gori::Tui::AdvancedSnapshot.new(
          conc: snap.conc, rate: snap.rate, timeout: snap.timeout, retries: snap.retries,
          max_requests: snap.max_requests, race: snap.race,
          follow: snap.follow, calibrate: snap.calibrate, keep_alive: snap.keep_alive,
          update_cl: snap.update_cl, reframe_grpc: snap.reframe_grpc,
          m_status: snap.m_status, m_size: snap.m_size, m_words: snap.m_words, m_regex: snap.m_regex,
          f_status: snap.f_status, f_size: snap.f_size, f_words: snap.f_words, f_regex: snap.f_regex,
          grpc_fields: "name"))
        with_surf_store do |store|
          engine, err = view.build_engine(false, Gori::Scope.load(store), nil)
          err.should be_nil
          engine.should_not be_nil
        end
        view.begin_run(nil) # freezes the template AND the composite the generator spliced through

        row = Gori::Fuzz::Result.new(0_i64, ["zz"], 0, 200, 0_i64, 0, 0, 1_i64, nil, false, false, nil)
        req = view.result_request(row)
        req.reconstructed.should be_true
        # One frame, framed correctly, carrying the typed field — not the capture with `zz`
        # appended past the end of it.
        Grpc.scan(Fuzz::GrpcVerdict.body(req.bytes).not_nil!)[1].should eq(0)
        rendered_message(req.bytes).should eq(
          Protobuf::Encoder.length_delimited(1_u32, "zz".to_slice))
      end
    end

    it "shows the builder's own sentence rather than prefixing it with `config error`" do
      Protobuf::Schemas.clear
      view = Gori::Tui::FuzzerView.new
      view.load_request("https://api.test", grpc_template("api.test"), false, "")
      view.apply_set(nil, Gori::Tui::SetSpec.new(:list, "a"))
      snap = view.advanced_snapshot
      view.apply_advanced(Gori::Tui::AdvancedSnapshot.new(
        conc: snap.conc, rate: snap.rate, timeout: snap.timeout, retries: snap.retries,
        max_requests: snap.max_requests, race: snap.race,
        follow: snap.follow, calibrate: snap.calibrate, keep_alive: snap.keep_alive,
        update_cl: snap.update_cl, reframe_grpc: snap.reframe_grpc,
        m_status: snap.m_status, m_size: snap.m_size, m_words: snap.m_words, m_regex: snap.m_regex,
        f_status: snap.f_status, f_size: snap.f_size, f_words: snap.f_words, f_regex: snap.f_regex,
        grpc_fields: "name"))
      with_surf_store do |store|
        engine, err = view.build_engine(false, Gori::Scope.load(store), nil)
        engine.should be_nil
        err.not_nil!.should contain("no descriptor set resolves")
        err.not_nil!.should_not contain("config error")
      end
    end
  end
end
