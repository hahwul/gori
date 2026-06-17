require "../store"

module Gori::Proxy
  # The boundary a connection writes captured flows to. Abstracting it (vs.
  # calling Store directly) keeps ClientConn testable with a recording double
  # and is the seam where intercept (P4) and extra notification could later hook.
  abstract class FlowSink
    # Persist a just-received request (Pending) and return its flow id.
    abstract def on_request(req : Store::CapturedRequest) : Int64
    # Fill in the response (or error) for an existing flow.
    abstract def on_response(resp : Store::CapturedResponse) : Nil
    # Record a captured WebSocket message for a flow (post-101).
    abstract def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes) : Nil

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
      @store.update_response(resp)
    end

    def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes) : Nil
      @store.insert_ws_message(flow_id, direction, opcode, payload)
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
