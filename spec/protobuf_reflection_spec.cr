require "./spec_helper"
require "./support/demo_descriptor"
require "socket"
require "base64"

private alias Frame = Gori::Proxy::H2::Frame
private alias HPACK = Gori::Proxy::H2::HPACK
private alias Reflection = Gori::Protobuf::Reflection
private alias Encoder = Gori::Protobuf::Encoder

# --- descriptor fixtures ------------------------------------------------------------------
#
# The reference `demo.desc` (a REAL protoc FileDescriptorSet, see support/demo_descriptor.cr)
# is what a reflection server would hand back, one FileDescriptorProto at a time — so the
# spec serves protoc's own bytes rather than an idea of them, and #827's third acceptance
# criterion ("fetched descriptors resolve exactly as a file-loaded set does") is checked
# against the file path's own answer.
private def demo_file_descriptor : Bytes
  set = Gori::Protobuf.decode(Base64.decode(DEMO_DESC_B64))
  set.fields.find { |f| f.number == 1 }.not_nil!.bytes.not_nil!
end

private def varint(v : UInt64) : Bytes
  io = IO::Memory.new
  while v > 0x7f_u64
    io.write_byte(((v & 0x7f_u64) | 0x80_u64).to_u8)
    v >>= 7
  end
  io.write_byte(v.to_u8)
  io.to_slice
end

# A minimal hand-built FileDescriptorProto: name (1), package (2), dependency (3, repeated),
# message_type (4). Enough to exercise the import walk without a second protoc artifact.
private def file_descriptor(name : String, package : String, deps : Array(String) = [] of String,
                            message : String? = nil) : Bytes
  io = IO::Memory.new
  io.write(Encoder.length_delimited(1_u32, name.to_slice))
  io.write(Encoder.length_delimited(2_u32, package.to_slice)) unless package.empty?
  deps.each { |d| io.write(Encoder.length_delimited(3_u32, d.to_slice)) }
  if message
    # DescriptorProto{ name = 1, field = 2 { name = 1, number = 3, label = 4, type = 5 } }
    field = IO::Memory.new
    field.write(Encoder.length_delimited(1_u32, "note".to_slice))
    field.write(Bytes[0x18]); field.write(varint(1_u64)) # number = 1
    field.write(Bytes[0x20]); field.write(varint(1_u64)) # label = LABEL_OPTIONAL
    field.write(Bytes[0x28]); field.write(varint(9_u64)) # type = TYPE_STRING
    msg = IO::Memory.new
    msg.write(Encoder.length_delimited(1_u32, message.to_slice))
    msg.write(Encoder.length_delimited(2_u32, field.to_slice))
    io.write(Encoder.length_delimited(4_u32, msg.to_slice))
  end
  io.to_slice
end

# ServerReflectionResponse builders — the shapes a real server returns.
private def list_services_response(names : Array(String)) : Bytes
  inner = IO::Memory.new
  names.each do |n|
    svc = Encoder.length_delimited(1_u32, n.to_slice) # ServiceResponse.name
    inner.write(Encoder.length_delimited(1_u32, svc)) # ListServiceResponse.service
  end
  Encoder.length_delimited(6_u32, inner.to_slice)
end

private def file_descriptor_response(blobs : Array(Bytes)) : Bytes
  inner = IO::Memory.new
  blobs.each { |b| inner.write(Encoder.length_delimited(1_u32, b)) }
  Encoder.length_delimited(4_u32, inner.to_slice)
end

private def error_response(code : Int32, message : String) : Bytes
  inner = IO::Memory.new
  inner.write(Bytes[0x08]); inner.write(varint(code.to_u64))
  inner.write(Encoder.length_delimited(2_u32, message.to_slice))
  Encoder.length_delimited(7_u32, inner.to_slice)
end

# --- the fake reflection origin -----------------------------------------------------------
#
# One cleartext-h2 listener that answers `ServerReflectionInfo` streams. It records the
# `:path` of every stream it served plus every request message it read, so a spec can assert
# BOTH what gori asked and — for the refusal examples — that it asked nothing at all.
private class ReflectOrigin
  getter port : Int32
  getter paths = [] of String
  # Each entry: the decoded ServerReflectionRequest, as {field_number, string_value}.
  getter asks = [] of {Int32, String}
  getter connections = 0

  # `unimplemented` lists the reflection service NAMES that answer grpc-status 12, so the
  # v1 → v1alpha fallback can be driven from a spec.
  def initialize(@unimplemented : Array(String) = [] of String,
                 @files : Hash(String, Bytes) = {} of String => Bytes,
                 @services : Array(String) = [] of String,
                 @symbol_error : String? = nil)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    @done = Channel(Nil).new(1)
    spawn { serve }
  end

  def close : Nil
    @server.close rescue nil
  end

  private def serve : Nil
    while conn = @server.accept?
      @connections += 1
      begin
        handle(conn)
      rescue
      ensure
        conn.close rescue nil
      end
    end
  rescue
  end

  private def handle(conn : TCPSocket) : Nil
    conn.read_timeout = 5.seconds
    Frame.read_preface(conn)
    conn.write(Frame::Header.new(Frame::Type::Settings.value, 0_u8, 0_u32, Bytes.empty).to_bytes)
    conn.flush
    dec = HPACK::Decoder.new
    path = ""
    body = IO::Memory.new
    loop do
      f = Frame.read(conn)
      break if f.nil?
      case f.frame_type
      when Frame::Type::Headers
        dec.decode(f.payload).each { |(n, v)| path = v if n == ":path" }
      when Frame::Type::Data
        body.write(f.payload)
      end
      break if f.frame_type.in?(Frame::Type::Headers, Frame::Type::Data) && f.end_stream?
    end
    @paths << path
    service = path.split('/')[1]? || ""
    enc = HPACK::Encoder.new
    if @unimplemented.includes?(service)
      blk = enc.encode([{":status", "200"}, {"content-type", "application/grpc"},
                        {"grpc-status", "12"}, {"grpc-message", "unknown service #{service}"}])
      conn.write(Frame::Header.new(Frame::Type::Headers.value,
        Frame::END_HEADERS | Frame::END_STREAM, 1_u32, blk).to_bytes)
      conn.flush
      return
    end
    requests, _ = Gori::Proxy::H2::Grpc.scan(body.to_slice)
    replies = requests.map { |m| answer(m) }
    blk = enc.encode([{":status", "200"}, {"content-type", "application/grpc"}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, blk).to_bytes)
    replies.each do |r|
      conn.write(Frame::Header.new(Frame::Type::Data.value, 0_u8, 1_u32,
        Gori::Proxy::H2::Grpc.frame(false, r)).to_bytes)
    end
    tb = enc.encode([{"grpc-status", "0"}])
    conn.write(Frame::Header.new(Frame::Type::Headers.value,
      Frame::END_HEADERS | Frame::END_STREAM, 1_u32, tb).to_bytes)
    conn.flush
  end

  private def answer(msg : Gori::Proxy::H2::Grpc::Message) : Bytes
    req = Gori::Protobuf.decode(msg.data)
    field = req.fields.find(&.number.in?(3_u32, 4_u32, 7_u32))
    return error_response(3, "no message_request") unless field
    value = field.string || ""
    @asks << {field.number.to_i32, value}
    case field.number
    when 7_u32 then list_services_response(@services)
    when 4_u32
      if e = @symbol_error
        error_response(5, e)
      else
        # A symbol maps to the file that declares it: the fixture keys files by the SYMBOL
        # they answer as well as by filename, which is what a real server's index does.
        blob = @files[value]?
        blob ? file_descriptor_response([blob]) : error_response(5, "symbol not found: #{value}")
      end
    else
      blob = @files[value]?
      blob ? file_descriptor_response([blob]) : error_response(5, "file not found: #{value}")
    end
  end
end

private def with_scope(&)
  path = File.tempname("gori-reflect", ".db")
  store = Gori::Store.open(path)
  begin
    yield Gori::Scope.load(store), store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

describe Gori::Protobuf::Reflection do
  describe "the request messages" do
    it "encodes list_services as the empty string on field 7" do
      m = Gori::Protobuf.decode(Reflection::Request.list_services)
      f = m.fields.first
      f.number.should eq(7_u32)
      f.bytes.not_nil!.size.should eq(0)
    end

    it "encodes file_containing_symbol on field 4 and file_by_filename on field 3" do
      sym = Gori::Protobuf.decode(Reflection::Request.symbol("demo.Users"))
      sym.fields.first.number.should eq(4_u32)
      sym.fields.first.string.should eq("demo.Users")
      fn = Gori::Protobuf.decode(Reflection::Request.filename("demo.proto"))
      fn.fields.first.number.should eq(3_u32)
      fn.fields.first.string.should eq("demo.proto")
    end

    # The `host` field (1) is documented as the virtual host and every server ignores it;
    # filling it in made vhost-routing servers answer NOT_FOUND for services they serve.
    it "never sends the ServerReflectionRequest.host field" do
      [Reflection::Request.list_services,
       Reflection::Request.symbol("x"),
       Reflection::Request.filename("y")].each do |r|
        Gori::Protobuf.decode(r).fields.any? { |f| f.number == 1_u32 }.should be_false
      end
    end
  end

  describe "descriptor bookkeeping" do
    it "wraps FileDescriptorProtos into a FileDescriptorSet the file parser accepts" do
      set = Reflection.descriptor_set([demo_file_descriptor])
      parsed = Gori::Protobuf::Schema.parse(set)
      parsed.should be_a(Gori::Protobuf::Schema)
      schema = parsed.as(Gori::Protobuf::Schema)
      # Identical to the file-loaded answer, declaration for declaration.
      schema.messages.keys.sort!.should eq(demo_schema.messages.keys.sort!)
      schema.methods.keys.sort!.should eq(demo_schema.methods.keys.sort!)
      schema.message?("demo.User").not_nil!.fields.should eq(demo_schema.message?("demo.User").not_nil!.fields)
    end

    it "reads a file's own name back off its octets" do
      Reflection.file_name(demo_file_descriptor).should eq("demo.proto")
    end

    it "lists only the dependencies no file in hand declares" do
      held = Reflection::Collected.new
      held.add(file_descriptor("a.proto", "a", ["b.proto", "c.proto"])).should be_true
      held.add(file_descriptor("b.proto", "b")).should be_true
      held.missing.should eq(["c.proto"])
    end

    it "holds a file once no matter how many services import it" do
      held = Reflection::Collected.new
      blob = file_descriptor("shared.proto", "shared")
      held.add(blob).should be_true
      held.add(blob).should be_false
      held.size.should eq(1)
    end

    it "reports an ErrorResponse as its gRPC status name and message" do
      m = Gori::Protobuf.decode(error_response(5, "symbol not found"))
      Reflection.error_response(m).should eq("NOT_FOUND: symbol not found")
    end

    it "returns nil for a reply that is not an ErrorResponse" do
      m = Gori::Protobuf.decode(list_services_response(["demo.Users"]))
      Reflection.error_response(m).should be_nil
    end
  end

  describe "the scope gate" do
    # #827's first acceptance criterion, and the half that matters most: the refusal must
    # happen BEFORE the dialer. The origin here is real and listening — if the gate leaked,
    # `connections` would be 1.
    it "refuses an out-of-scope target without opening a connection" do
      origin = ReflectOrigin.new(services: ["demo.Users"], files: {"demo.Users" => demo_file_descriptor})
      begin
        with_scope do |scope, store|
          store.add_scope_rule("include", "host", "elsewhere.test")
          scope.reload
          client = Reflection::Client.new(Gori::Outbound.agent(scope, false),
            scheme: "http", host: "127.0.0.1", port: origin.port, verify: false)
          outcome = client.fetch
          outcome.refused?.should be_true
          outcome.ok?.should be_false
          outcome.error.not_nil!.should contain("out_of_scope")
          origin.connections.should eq(0)
          origin.paths.should be_empty
        end
      ensure
        origin.close
      end
    end

    it "refuses an unscoped project on the agent gate, and says which rule to add" do
      origin = ReflectOrigin.new
      begin
        with_scope do |scope, _store|
          client = Reflection::Client.new(Gori::Outbound.agent(scope, false),
            scheme: "http", host: "127.0.0.1", port: origin.port, verify: false)
          client.refusal.not_nil!.should contain("add a scope include rule")
          client.fetch.refused?.should be_true
          origin.connections.should eq(0)
        end
      ensure
        origin.close
      end
    end

    # Layer 2 holds even where Layer 1 is waived — the TUI's own policy, where the operator
    # picked the row. Sandbox is the rule `allow_unscoped` deliberately does not lift.
    it "refuses under Sandbox even with layer 1 waived" do
      origin = ReflectOrigin.new
      begin
        with_scope do |scope, _store|
          scope.enable_sandbox
          client = Reflection::Client.new(Gori::Outbound.interactive(scope),
            scheme: "http", host: "127.0.0.1", port: origin.port, verify: false)
          outcome = client.fetch
          outcome.refused?.should be_true
          outcome.error.not_nil!.should contain("sandbox")
          origin.connections.should eq(0)
        end
      ensure
        origin.close
      end
    end

    # The fallback may send EITHER path, so an include rule that covers only `v1` cannot be
    # read as permission for the whole fetch. Fail-closed: the stricter of the two answers.
    it "gates BOTH reflection paths, not only the one tried first" do
      origin = ReflectOrigin.new
      begin
        with_scope do |scope, store|
          store.add_scope_rule("include", "string", Reflection.path(Reflection::SERVICE_V1))
          scope.reload
          client = Reflection::Client.new(Gori::Outbound.agent(scope, false),
            scheme: "http", host: "127.0.0.1", port: origin.port, verify: false)
          # The v1 path alone WOULD pass this rule…
          Gori::Outbound.agent(scope, false)
            .check_request("http", "127.0.0.1", Reflection.path(Reflection::SERVICE_V1), origin.port)
            .blocked?.should be_false
          # …but the fetch is still refused, because the v1alpha path is not covered.
          client.refusal.should_not be_nil
          client.fetch.refused?.should be_true
          origin.connections.should eq(0)
        end
      ensure
        origin.close
      end
    end

    it "proceeds for an in-scope target" do
      origin = ReflectOrigin.new(services: ["demo.Users"], files: {"demo.Users" => demo_file_descriptor})
      begin
        with_scope do |scope, store|
          store.add_scope_rule("include", "host", "127.0.0.1")
          scope.reload
          client = Reflection::Client.new(Gori::Outbound.agent(scope, false),
            scheme: "http", host: "127.0.0.1", port: origin.port, verify: false, timeout: 5.seconds)
          client.refusal.should be_nil
          outcome = client.fetch
          outcome.ok?.should be_true
          origin.connections.should be > 0
        end
      ensure
        origin.close
      end
    end
  end

  describe "fetching against a server" do
    it "lists services, fetches their files, and produces a schema identical to the file's" do
      origin = ReflectOrigin.new(services: ["demo.Users"],
        files: {"demo.Users" => demo_file_descriptor, "demo.proto" => demo_file_descriptor})
      begin
        with_scope do |scope, _store|
          client = Reflection::Client.new(Gori::Outbound.interactive(scope),
            scheme: "http", host: "127.0.0.1", port: origin.port, verify: false, timeout: 5.seconds)
          outcome = client.fetch
          outcome.error.should be_nil
          outcome.ok?.should be_true
          outcome.version.should eq("v1")
          outcome.services.should eq(["demo.Users"])
          outcome.files.should eq(1)
          schema = outcome.schema.not_nil!
          schema.method?("/demo.Users/GetUser").not_nil!.input_type.should eq("demo.GetUserRequest")
          schema.message?("demo.User").not_nil!.fields.should eq(demo_schema.message?("demo.User").not_nil!.fields)
          # One stream per round: list_services, then the symbol.
          origin.asks.should eq([{7, ""}, {4, "demo.Users"}])
          origin.paths.uniq.should eq([Reflection.path(Reflection::SERVICE_V1)])
        end
      ensure
        origin.close
      end
    end

    # #827's second acceptance criterion.
    it "falls back to v1alpha when v1 answers UNIMPLEMENTED" do
      origin = ReflectOrigin.new(unimplemented: [Reflection::SERVICE_V1],
        services: ["demo.Users"], files: {"demo.Users" => demo_file_descriptor})
      begin
        with_scope do |scope, _store|
          outcome = Reflection::Client.new(Gori::Outbound.interactive(scope),
            scheme: "http", host: "127.0.0.1", port: origin.port, verify: false, timeout: 5.seconds).fetch
          outcome.ok?.should be_true
          outcome.version.should eq("v1alpha")
          outcome.service.should eq(Reflection::SERVICE_V1ALPHA)
          origin.paths.first.should eq(Reflection.path(Reflection::SERVICE_V1))
          origin.paths[1].should eq(Reflection.path(Reflection::SERVICE_V1ALPHA))
        end
      ensure
        origin.close
      end
    end

    it "says so when neither service is implemented, rather than failing silently" do
      origin = ReflectOrigin.new(
        unimplemented: [Reflection::SERVICE_V1, Reflection::SERVICE_V1ALPHA])
      begin
        with_scope do |scope, _store|
          outcome = Reflection::Client.new(Gori::Outbound.interactive(scope),
            scheme: "http", host: "127.0.0.1", port: origin.port, verify: false, timeout: 5.seconds).fetch
          outcome.ok?.should be_false
          outcome.refused?.should be_false
          outcome.error.not_nil!.should contain("UNIMPLEMENTED")
          outcome.schema.should be_nil
        end
      ensure
        origin.close
      end
    end

    it "follows a dependency the first round did not carry" do
      leaf = file_descriptor("dep.proto", "dep", message: "Leaf")
      root = file_descriptor("root.proto", "root", ["dep.proto"], message: "Root")
      origin = ReflectOrigin.new(services: ["root.Svc"],
        files: {"root.Svc" => root, "dep.proto" => leaf})
      begin
        with_scope do |scope, _store|
          outcome = Reflection::Client.new(Gori::Outbound.interactive(scope),
            scheme: "http", host: "127.0.0.1", port: origin.port, verify: false, timeout: 5.seconds).fetch
          outcome.ok?.should be_true
          outcome.files.should eq(2)
          outcome.schema.not_nil!.message?("dep.Leaf").should_not be_nil
          origin.asks.should eq([{7, ""}, {4, "root.Svc"}, {3, "dep.proto"}])
        end
      ensure
        origin.close
      end
    end

    it "keeps the files it did get when one symbol errors, and names the symbol" do
      origin = ReflectOrigin.new(services: ["demo.Users"], symbol_error: "no such symbol")
      begin
        with_scope do |scope, _store|
          outcome = Reflection::Client.new(Gori::Outbound.interactive(scope),
            scheme: "http", host: "127.0.0.1", port: origin.port, verify: false, timeout: 5.seconds).fetch
          outcome.ok?.should be_false
          outcome.error.not_nil!.should contain("returned no descriptors")
          outcome.notes.any?(&.includes?("demo.Users")).should be_true
        end
      ensure
        origin.close
      end
    end

    it "reports a server that lists nothing rather than caching an empty schema" do
      origin = ReflectOrigin.new(services: [] of String)
      begin
        with_scope do |scope, _store|
          outcome = Reflection::Client.new(Gori::Outbound.interactive(scope),
            scheme: "http", host: "127.0.0.1", port: origin.port, verify: false, timeout: 5.seconds).fetch
          outcome.ok?.should be_false
          outcome.error.not_nil!.should contain("listed no services")
          outcome.descriptor_set.should be_nil
        end
      ensure
        origin.close
      end
    end

    it "marks a connect failure as TRANSPORT and a service answer as not" do
      closed = TCPServer.new("127.0.0.1", 0)
      dead = closed.local_address.port
      closed.close
      origin = ReflectOrigin.new(
        unimplemented: [Reflection::SERVICE_V1, Reflection::SERVICE_V1ALPHA])
      begin
        with_scope do |scope, _store|
          Reflection::Client.new(Gori::Outbound.interactive(scope),
            scheme: "http", host: "127.0.0.1", port: dead, verify: false, timeout: 2.seconds)
            .fetch.transport?.should be_true
          # A server that ANSWERED "I do not implement this" is a stable answer: re-asking
          # gets the same sentence, which is exactly what an agent must not retry-loop on.
          Reflection::Client.new(Gori::Outbound.interactive(scope),
            scheme: "http", host: "127.0.0.1", port: origin.port, verify: false, timeout: 5.seconds)
            .fetch.transport?.should be_false
        end
      ensure
        origin.close
      end
    end

    it "reports a connect failure as itself, not as an UNIMPLEMENTED fallback" do
      # A closed port: `open` fails, so nothing about the SERVICE can be concluded and the
      # v1alpha retry must not fire.
      closed = TCPServer.new("127.0.0.1", 0)
      port = closed.local_address.port
      closed.close
      with_scope do |scope, _store|
        outcome = Reflection::Client.new(Gori::Outbound.interactive(scope),
          scheme: "http", host: "127.0.0.1", port: port, verify: false, timeout: 2.seconds).fetch
        outcome.ok?.should be_false
        outcome.refused?.should be_false
        outcome.error.not_nil!.should_not contain("v1alpha")
      end
    end
  end
end
