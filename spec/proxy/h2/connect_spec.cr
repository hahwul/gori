require "../../spec_helper"
require "compress/gzip"

private alias Connect = Gori::Proxy::H2::Connect
private alias Grpc = Gori::Proxy::H2::Grpc

# A Connect envelope: 1-byte flag + 4-byte big-endian length + payload.
private def envelope(payload : String | Bytes, flag : UInt8 = 0_u8) : Bytes
  data = payload.is_a?(String) ? payload.to_slice : payload
  io = IO::Memory.new
  io.write_byte(flag)
  io.write_bytes(data.size.to_u32, IO::ByteFormat::BigEndian)
  io.write(data)
  io.to_slice
end

private def head(text : String) : Bytes
  text.gsub("\n", "\r\n").to_slice
end

private UNARY_PROTO = head("POST /demo.Users/GetUser HTTP/1.1\nHost: api.test\n" \
                           "Content-Type: application/proto\nConnect-Protocol-Version: 1\n\n")
private UNARY_JSON = head("POST /demo.Users/GetUser HTTP/1.1\nHost: api.test\n" \
                          "Content-Type: application/json\nConnect-Protocol-Version: 1\n\n")
private PLAIN_JSON   = head("POST /api/users HTTP/1.1\nHost: api.test\nContent-Type: application/json\n\n")
private STREAM_PROTO = head("POST /demo.Users/Watch HTTP/2\nHost: api.test\nContent-Type: application/connect+proto\n\n")

describe Gori::Proxy::H2::Connect do
  describe "detection" do
    it "names a unary proto call by the request's connect-protocol-version" do
      Connect.call?(UNARY_PROTO).should be_true
      Connect.unary?(UNARY_PROTO).should be_true
      Connect.unary_proto?(UNARY_PROTO, "application/proto").should be_true
      # The response half is protobuf too, and still named by the REQUEST head.
      Connect.unary_proto?(UNARY_PROTO, "application/proto; charset=x").should be_true
    end

    it "names a unary json call, with no protobuf view for its body" do
      Connect.call?(UNARY_JSON).should be_true
      Connect.unary_proto?(UNARY_JSON, "application/json").should be_false
      Grpc.scan_call(UNARY_JSON, UNARY_JSON, %({"id":1}).to_slice).should be_nil
    end

    it "names a stream by its content type alone" do
      Connect.call?(STREAM_PROTO).should be_true
      Connect.unary?(STREAM_PROTO).should be_false
      Connect.streaming?("Application/Connect+JSON; charset=utf-8").should be_true
    end

    it "does not treat a plain application/json request as Connect" do
      Connect.call?(PLAIN_JSON).should be_false
      Grpc.scan_call(PLAIN_JSON, PLAIN_JSON, %({"id":1}).to_slice).should be_nil
      Connect.outcome(PLAIN_JSON, 403, head("HTTP/1.1 403 Forbidden\nContent-Type: application/json\n\n"),
        %({"code":"permission_denied","message":"no"}).to_slice).should be_nil
    end
  end

  describe "scan_call" do
    it "reads a unary proto body as ONE message, with no envelope" do
      body = Bytes[0x0a, 0x05, 0x61, 0x6c, 0x69, 0x63, 0x65]
      msgs, residual = Grpc.scan_call(UNARY_PROTO, UNARY_PROTO, body).not_nil!
      residual.should eq(0)
      msgs.size.should eq(1)
      msgs[0].data.should eq(body)
      msgs[0].json.should be_false
    end

    it "undoes a unary body's content-encoding" do
      body = Bytes[0x0a, 0x01, 0x61]
      io = IO::Memory.new
      Compress::Gzip::Writer.open(io, &.write(body))
      resp = head("HTTP/1.1 200 OK\nContent-Type: application/proto\nContent-Encoding: gzip\n\n")
      msgs, _ = Grpc.scan_call(UNARY_PROTO, resp, io.to_slice).not_nil!
      msgs[0].data.should eq(body)
    end

    # A codec gori cannot undo leaves the octets coded: no tree over them, the plain body view
    # (with its decode note) takes the body instead.
    it "is nil for a unary body whose content-encoding did not come off" do
      body = Bytes[0x0a, 0x01, 0x61]
      %w[x-custom gzip].each do |enc|
        resp = head("HTTP/1.1 200 OK\nContent-Type: application/proto\nContent-Encoding: #{enc}\n\n")
        Grpc.scan_call(UNARY_PROTO, resp, body).should be_nil # not a gzip stream either
      end
      io = IO::Memory.new
      Compress::Gzip::Writer.open(io, &.write(Bytes.new(64, 0x41_u8)))
      cut = io.to_slice[0, io.size - 12] # a gzip stream cut before its end
      resp = head("HTTP/1.1 200 OK\nContent-Type: application/proto\nContent-Encoding: gzip\n\n")
      Grpc.scan_call(UNARY_PROTO, resp, cut).should be_nil
    end

    it "flags a stream's end-stream message (0x02) as JSON, and never as a trailer" do
      resp = head("HTTP/2 200 OK\nContent-Type: application/connect+proto\n\n")
      body = envelope(Bytes[0x0a, 0x01, 0x61]) + envelope(%({"metadata":{}}), 0x82_u8)
      msgs, residual = Grpc.scan_call(STREAM_PROTO, resp, body).not_nil!
      residual.should eq(0)
      msgs.map(&.end_stream).should eq([false, true])
      msgs.map(&.json).should eq([false, true])
      msgs.any?(&.trailer).should be_false
    end

    it "marks every payload of a +json stream as JSON" do
      resp = head("HTTP/2 200 OK\nContent-Type: application/connect+json\n\n")
      msgs, _ = Grpc.scan_call(nil, resp, envelope(%({"a":1}))).not_nil!
      msgs[0].json.should be_true
      msgs[0].end_stream.should be_false
    end

    it "leaves native gRPC's flag byte as it was" do
      resp = head("HTTP/2 200 OK\nContent-Type: application/grpc-web\n\n")
      msgs, _ = Grpc.scan_call(nil, resp, envelope("grpc-status: 0\r\n", 0x80_u8)).not_nil!
      msgs[0].trailer.should be_true
      msgs[0].end_stream.should be_false
    end
  end

  describe "outcome" do
    it "reads a unary error from a non-200 JSON body" do
      resp = head("HTTP/1.1 403 Forbidden\nContent-Type: application/json\n\n")
      o = Connect.outcome(UNARY_PROTO, 403, resp,
        %({"code":"permission_denied","message":"not yours","details":[]}).to_slice).not_nil!
      o.code.should eq("permission_denied")
      o.message.should eq("not yours")
    end

    it "has none for a successful unary call" do
      resp = head("HTTP/1.1 200 OK\nContent-Type: application/json\n\n")
      Connect.outcome(UNARY_JSON, 200, resp, %({"code":"x"}).to_slice).should be_nil
    end

    it "has none for a non-JSON error body" do
      resp = head("HTTP/1.1 502 Bad Gateway\nContent-Type: text/html\n\n")
      Connect.outcome(UNARY_PROTO, 502, resp, "<html>".to_slice).should be_nil
      Connect.outcome(UNARY_PROTO, 502, resp, "[1]".to_slice).should be_nil
    end

    it "reads a stream's error from its end-stream message" do
      resp = head("HTTP/2 200 OK\nContent-Type: application/connect+proto\n\n")
      body = envelope(Bytes[0x0a, 0x01, 0x61]) +
             envelope(%({"error":{"code":"unauthenticated","message":"token expired"}}), 0x02_u8)
      o = Connect.outcome(STREAM_PROTO, 200, resp, body).not_nil!
      o.code.should eq("unauthenticated")
      o.message.should eq("token expired")
    end

    it "inflates a compressed end-stream message under connect-content-encoding" do
      io = IO::Memory.new
      Compress::Gzip::Writer.open(io, &.write(%({"error":{"code":"internal"}}).to_slice))
      resp = head("HTTP/2 200 OK\nContent-Type: application/connect+proto\nConnect-Content-Encoding: gzip\n\n")
      o = Connect.outcome(STREAM_PROTO, 200, resp, envelope(io.to_slice, 0x03_u8)).not_nil!
      o.code.should eq("internal")
      o.message.should be_nil
    end

    it "says whether a stream reached its end-stream message" do
      resp = head("HTTP/2 200 OK\nContent-Type: application/connect+proto\n\n")
      Connect.end_stream?(resp, envelope(Bytes[0x0a, 0x01, 0x61])).should be_false
      Connect.end_stream?(resp, envelope(%({}), 0x02_u8)).should be_true
      Connect.end_stream?(head("HTTP/1.1 200 OK\nContent-Type: application/proto\n\n"), nil).should be_nil
    end

    it "has none for a stream that ended cleanly" do
      resp = head("HTTP/2 200 OK\nContent-Type: application/connect+proto\n\n")
      Connect.outcome(STREAM_PROTO, 200, resp, envelope(%({"metadata":{}}), 0x02_u8)).should be_nil
    end
  end
end
