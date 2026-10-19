require "../spec_helper"
require "../support/demo_descriptor"
require "socket"
require "file_utils"

# #1632: the headless field set reaches `gori run repeater send` and MCP `send_request`
# through the one function the TUI's add-field prompt calls. The engine is pinned byte for
# byte in spec/protobuf/edit_spec.cr and spec/repeater/grpc_fields_spec.cr; what can rot here
# is a surface that stops handing its input over.

private alias Grpc = Gori::Proxy::H2::Grpc

private def with_demo_schema(&)
  dir = File.tempname("gori-grpcset-surf")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "demo.desc"), Base64.decode(DEMO_DESC_B64))
  Gori::Protobuf::Schemas.apply(dir)
  yield
ensure
  Gori::Protobuf::Schemas.clear
  FileUtils.rm_rf(dir) if dir
end

private def with_set_store(&)
  path = File.tempname("gori-grpcset", ".db")
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

# An HTTP/1.1 origin that records each request body and answers 200.
private class BodyOrigin
  getter port : Int32
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

private def get_user_raw : String
  frame = Grpc.frame(false, Gori::Protobuf::Encoder.length_delimited(1_u32, "bob".to_slice))
  "POST /demo.Users/GetUser HTTP/1.1\r\nHost: 127.0.0.1\r\ncontent-type: application/grpc\r\n" \
  "content-length: #{frame.size}\r\n\r\n#{String.new(frame)}"
end

describe "the gRPC field set reaches every headless send surface" do
  it "both surfaces hand their input to Repeater::GrpcFields.apply" do
    root = File.expand_path(File.join(__DIR__, "..", ".."))
    {
      "src/gori/cli/run/repeater.cr" => "--grpc-field",
      "src/gori/mcp/tools/send.cr"   => %("grpc_fields"),
    }.each do |rel, own_input|
      src = File.read(File.join(root, rel))
      src.should contain("Repeater::GrpcFields.apply")
      src.should contain(own_input)
    end
    # …and the TUI's prompt calls the engine function the wrapper calls.
    File.read(File.join(root, "src/gori/tui/repeater_view/grpc_fields.cr")).should contain("Protobuf::Edit.set")
    File.read(File.join(root, "src/gori/repeater/grpc_fields.cr")).should contain("Protobuf::Edit.set")
  end

  describe "MCP send_request{grpc_fields}" do
    it "sets a field by name and the origin receives the re-encoded, reframed message" do
      origin = BodyOrigin.new
      begin
        with_set_store do |store|
          tools = tools_for(store)
          with_demo_schema do
            args = {"url" => "http://127.0.0.1:#{origin.port}", "raw" => get_user_raw,
                    "grpc_fields" => ["name=administrator"], "allow_unscoped" => true,
                    "record_history" => false}
            r = tools.call("send_request", JSON.parse(args.to_json))
            fail r.text if r.is_error
          end
        end
        origin.bodies.size.should eq(1)
        msgs, residual = Grpc.scan(origin.bodies[0])
        residual.should eq(0)
        msgs[0].data.should eq(Gori::Protobuf::Encoder.length_delimited(1_u32, "administrator".to_slice))
      ensure
        origin.close
      end
    end

    it "puts the same message on the wire as `gori run repeater send --grpc-field`" do
      origin = BodyOrigin.new
      begin
        cli_body = nil.as(Bytes?)
        with_set_store do |store|
          tools = tools_for(store)
          with_demo_schema do
            specs = ["name=administrator", "7:varint=1"]
            args = {"url" => "http://127.0.0.1:#{origin.port}", "raw" => get_user_raw,
                    "grpc_fields" => specs, "allow_unscoped" => true, "record_history" => false}
            r = tools.call("send_request", JSON.parse(args.to_json))
            fail r.text if r.is_error
            built = Gori::CLI::Run.per_send_request(get_user_raw.to_slice, [] of String, specs)
            cli_body = Gori::Fuzz::GrpcVerdict.body(built.as({Bytes, Bool})[0])
          end
        end
        origin.bodies.size.should eq(1)
        cli_body.should eq(origin.bodies[0])
      ensure
        origin.close
      end
    end

    it "removes a field with -path, and refuses one the message lacks before anything dials" do
      origin = BodyOrigin.new
      begin
        with_set_store do |store|
          tools = tools_for(store)
          Gori::Protobuf::Schemas.clear
          base = {"url" => "http://127.0.0.1:#{origin.port}", "raw" => get_user_raw,
                  "allow_unscoped" => true, "record_history" => false}
          r = tools.call("send_request", JSON.parse(base.merge({"grpc_fields" => ["-2"]}).to_json))
          r.is_error.should be_true
          r.text.should contain("not on this message")
          origin.bodies.should be_empty
          r = tools.call("send_request", JSON.parse(base.merge({"grpc_fields" => ["-1"]}).to_json))
          fail r.text if r.is_error
        end
        origin.bodies.size.should eq(1)
        msgs, residual = Grpc.scan(origin.bodies[0])
        residual.should eq(0)
        msgs[0].data.should be_empty
      ensure
        origin.close
      end
    end

    it "refuses a spec it cannot apply before anything dials" do
      origin = BodyOrigin.new
      begin
        with_set_store do |store|
          tools = tools_for(store)
          Gori::Protobuf::Schemas.clear
          args = {"url" => "http://127.0.0.1:#{origin.port}", "raw" => get_user_raw,
                  "grpc_fields" => ["is_admin=true"], "allow_unscoped" => true}
          r = tools.call("send_request", JSON.parse(args.to_json))
          r.is_error.should be_true
          r.text.should contain("grpc_fields")
          r.text.should contain("no .proto schema")
        end
        origin.bodies.should be_empty
      ensure
        origin.close
      end
    end
  end
end
