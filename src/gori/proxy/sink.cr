require "../store"
require "./ws/frame"

module Gori::Proxy
  # The boundary a connection writes captured flows to. Abstracting it (vs.
  # calling Store directly) keeps ClientConn testable with a recording double
  # and is the seam where intercept (P4) and extra notification could later hook.
  abstract class FlowSink
    # Persist a just-received request (Pending) and return its flow id.
    abstract def on_request(req : Store::CapturedRequest) : Int64
    # Fill in the response (or error) for an existing flow.
    abstract def on_response(resp : Store::CapturedResponse) : Nil
    # Record a captured WebSocket message for a flow (post-101). `shape` is the frame
    # header the payload arrived in (V7); the default spares every CALLER from passing it.
    # It does NOT spare an implementor: Crystal matches an abstract def by its full parameter
    # list, so a sink that omits `shape` no longer satisfies this and fails to compile. Two
    # bench sinks were left behind exactly that way, and because CI does not build `bench/`
    # (see .github/workflows/ci.yml) nothing said so until someone tried to run one.
    abstract def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                               shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil

    # --- HTTP/2 (raw-frame fidelity) -----------------------------------------
    # Default no-ops so non-h2 sinks (and test doubles) need not implement them.

    # Open an intercepted h2 connection; returns its id for frame attribution.
    def on_h2_open(host : String, port : Int32, alpn : String) : Int64
      0_i64
    end

    # Record one raw h2 frame (already forwarded; capture must not stall traffic).
    def on_h2_frame(conn_id : Int64, direction : String, type : UInt8, flags : UInt8,
                    stream_id : UInt32, payload : Bytes) : Nil
    end
  end

  # Default sink: writes straight through to the SQLite store.
  class StoreSink < FlowSink
    def initialize(@store : Store)
    end

    def on_request(req : Store::CapturedRequest) : Int64
      @store.insert_flow(req)
    end

    def on_response(resp : Store::CapturedResponse) : Nil
      return if resp.flow_id <= 0 # the request insert failed (e.g. disk full) — no row to update
      @store.update_response(resp)
    end

    def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                      shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
      return if flow_id <= 0
      @store.insert_ws_message(flow_id, direction, opcode, payload, shape: shape)
    end

    def on_h2_open(host : String, port : Int32, alpn : String) : Int64
      @store.insert_h2_connection(host, port, alpn)
    end

    def on_h2_frame(conn_id : Int64, direction : String, type : UInt8, flags : UInt8,
                    stream_id : UInt32, payload : Bytes) : Nil
      @store.insert_h2_frame(conn_id, direction, type, flags, stream_id, payload)
    end
  end
end
