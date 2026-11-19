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

    # `on_request` for a caller that does not need the id yet: the channel answers it. A sink
    # that can queue the write (StoreSink) returns before the commit; the default answers at
    # once, so a recording double behaves exactly as it does under `on_request`.
    def on_request_deferred(req : Store::CapturedRequest) : Channel(Int64)
      id = Channel(Int64).new(1)
      id.send(on_request(req))
      id
    end

    # `on_response` without waiting for the write to land; the default is `on_response`.
    def on_response_deferred(resp : Store::CapturedResponse) : Nil
      on_response(resp)
    end

    # Record a captured WebSocket message for a flow (post-101). `shape` is the frame
    # header the payload arrived in (V7); the default spares every CALLER from passing it.
    # It does NOT spare an implementor: Crystal matches an abstract def by its full parameter
    # list, so a sink that omits `shape` no longer satisfies this and fails to compile. Two
    # bench sinks were left behind exactly that way, and because CI does not build `bench/`
    # (see .github/workflows/ci.yml) nothing said so until someone tried to run one.
    abstract def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                               shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil

    # A frame gori INJECTED into the live socket (#1630), recorded as a message of its own so
    # readers can mark it. The default records it as an ordinary message, so a sink that does
    # not keep the origin (a bench or test double) still compiles and still sees it.
    def on_ws_injected(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                       shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
      on_ws_message(flow_id, direction, opcode, payload, shape)
    end

    # Match&Replace rules that rewrote a WebSocket message on `flow_id`, recorded the first time
    # each one does (#1589). The default keeps sinks that only record HTTP flows source-compatible.
    def on_rule_hits(flow_id : Int64, side : Store::RuleTarget, hits : Array(Store::RuleRef)) : Nil
    end

    # Append part of a still-streaming event-stream body at offset `off` (#1631), with the
    # Pending response `head` on the first append, and `times`, the packed arrivals of the
    # events numbered from `first` on that completed since the last taken append. Must not
    # block; true when it was taken. The default discards it, so a sink that records only
    # finished flows needs nothing.
    def on_live_body(flow_id : Int64, off : Int64, bytes : Bytes, head : Store::CapturedResponse?,
                     first : Int32, times : Bytes) : Bool
      true
    end

    # Called after an upgraded tunnel closes and its captured transcript has been written.
    # The default keeps sinks that only record HTTP flows source-compatible.
    def on_tunnel_complete(flow_id : Int64) : Nil
    end

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
    # The largest body or WebSocket payload queued without waiting for its commit. The writer
    # channel holds 1024 ops, so this bounds what queued capture can pin at ~64 MiB.
    DEFER_MAX = 64 * 1024

    def initialize(@store : Store)
    end

    def on_request(req : Store::CapturedRequest) : Int64
      @store.insert_flow(req)
    end

    def on_response(resp : Store::CapturedResponse) : Nil
      return if resp.flow_id <= 0 # the request insert failed (e.g. disk full) — no row to update
      @store.update_response(resp)
    end

    def on_request_deferred(req : Store::CapturedRequest) : Channel(Int64)
      @store.insert_flow_deferred(req)
    end

    def on_response_deferred(resp : Store::CapturedResponse) : Nil
      return if resp.flow_id <= 0
      # ponytail: a size cutoff, not a byte budget. A big body waits for its commit as before, so
      # queued writes hold at most DEFER_MAX each; a per-connection in-flight budget if this bites.
      return @store.update_response(resp) if (resp.body.try(&.size) || 0) > DEFER_MAX
      @store.update_response_deferred(resp)
    end

    def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                      shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
      return if flow_id <= 0
      # The peer picks the message size (up to 16 MiB), so only small ones ride the queue.
      return @store.insert_ws_message(flow_id, direction, opcode, payload, shape: shape) if payload.size > DEFER_MAX
      @store.queue_ws_message(flow_id, direction, opcode, payload, shape: shape)
    end

    def on_ws_injected(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                       shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
      return if flow_id <= 0
      @store.insert_ws_message(flow_id, direction, opcode, payload, shape: shape,
        origin: Store::WsMessage::ORIGIN_GORI)
    end

    def on_rule_hits(flow_id : Int64, side : Store::RuleTarget, hits : Array(Store::RuleRef)) : Nil
      @store.record_rule_hits(flow_id, side, hits)
    end

    def on_live_body(flow_id : Int64, off : Int64, bytes : Bytes, head : Store::CapturedResponse?,
                     first : Int32, times : Bytes) : Bool
      return true if flow_id <= 0 # no row to append to
      @store.append_live(flow_id, off, bytes, head, first, times)
    end

    # After the transcript's queued messages commit, so the event still follows the whole
    # captured transcript (`on_ws_message` does not wait for them).
    def on_tunnel_complete(flow_id : Int64) : Nil
      @store.await_writes
      @store.notify_tunnel_complete(flow_id)
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
