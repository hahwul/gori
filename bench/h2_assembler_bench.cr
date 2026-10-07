# h2 Assembler per-exchange allocation micro-benchmark. `Assembler#feed` runs for every
# HEADERS/DATA frame of every h2 flow, and each stream it tracks builds two `Side`s. This
# drives one plain GET exchange (request HEADERS + END_STREAM, response HEADERS, one DATA +
# END_STREAM) through the assembler with a discarding sink and reports bytes/op — the
# number that moves when per-stream bookkeeping is allocated eagerly vs on first use.
#
# Build: crystal build bench/h2_assembler_bench.cr -o bin/h2_assembler_bench --release
# Run:   bin/h2_assembler_bench
require "benchmark"

module Gori
  class Error < Exception; end

  # client_conn stamps this into the CONNECT-failure page; see proxy_bench.cr.
  VERSION = "0.0.0-bench"
end

require "../src/gori/proxy/h2/assembler"
require "../src/gori/proxy/sink"

class NullSink < Gori::Proxy::FlowSink
  getter responses = 0

  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
    @responses += 1
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

include Gori::Proxy::H2

# The default encoder never touches its dynamic table, so one block decodes the same on
# every iteration and the assembler's decoders stay in step.
REQ = HPACK::Encoder.new.encode([{":method", "GET"}, {":scheme", "https"},
                                 {":authority", "api.example.com"}, {":path", "/api/v1/users/1"},
                                 {"accept", "application/json"}])
RESP = HPACK::Encoder.new.encode([{":status", "200"}, {"content-type", "application/json"},
                                  {"content-length", "27"}])
BODY = "{\"id\":1,\"name\":\"example\"}".to_slice

REQ_HEADERS  = Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS | Frame::END_STREAM, 1_u32, REQ)
RESP_HEADERS = Frame::Header.new(Frame::Type::Headers.value, Frame::END_HEADERS, 1_u32, RESP)
RESP_DATA    = Frame::Header.new(Frame::Type::Data.value, Frame::END_STREAM, 1_u32, BODY)

SINK      = NullSink.new
ASSEMBLER = Assembler.new(SINK, "api.example.com", 443)

def exchange : Nil
  ASSEMBLER.feed("out", REQ_HEADERS)
  ASSEMBLER.feed("in", RESP_HEADERS)
  ASSEMBLER.feed("in", RESP_DATA)
end

exchange
raise "the exchange did not complete" unless SINK.responses == 1

Benchmark.ips do |x|
  x.report("one GET exchange (3 frames)") { exchange }
end
