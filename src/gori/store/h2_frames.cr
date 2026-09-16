require "db"

module Gori
  class Store
    # --- HTTP/2 raw-frame log ------------------------------------------------

    def insert_h2_connection(host : String, port : Int32, alpn : String) : Int64
      ts = now_us
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO h2_connections (created_at, host, port, alpn) VALUES (?,?,?,?)", ts, host, port, alpn)
        nil
      }
    end

    # Records one raw h2 frame, FIRE-AND-FORGET — never blocks the caller (the h2
    # relay pump). The frame queues to the writer (batched there); if the writer is
    # saturated it is DROPPED and a counter bumped, rather than backpressuring the
    # relay's forwarding loop. No reply is awaited (the relay never needs the id).
    def insert_h2_frame(conn_id : Int64, direction : String, type : UInt8, flags : UInt8,
                        stream_id : UInt32, payload : Bytes) : Nil
      # A frame with no connection row to hang off is not a log entry, it is landfill, and it
      # is the ONE kind of row the retention sweep can never take back: the sweep reaps
      # `h2_frames WHERE conn_id IN (SELECT id FROM h2_connections WHERE <stale>)`, and there is
      # no `h2_connections` row with id 0 for it to select. Measured: 6 such frames survived a
      # sweep that took the flow table from 20 rows to 2, and they stay for the life of the file
      # (only `compact --h2-frames`, which drops the whole log, gets rid of them).
      #
      # 0 arrives two ways, and both mean "do not log": `FlowSink#on_h2_open`'s default returns
      # it for a sink that keeps no frame log, and `StoreSink#on_h2_open` returns it when
      # `insert_h2_connection` did not commit. Guarded here rather than in the sink so every
      # caller is covered by one rule — the sink's two siblings, `on_response` and
      # `on_ws_message`, already refuse a non-positive parent id for the same reason.
      #
      # NOT counted in `h2_frames_dropped`: that number is labelled "the writer was saturated"
      # where the TUI shows it, and this is not that.
      return if conn_id <= 0
      op = InsertH2Frame.new(conn_id, now_us, direction, type.to_i32, flags.to_i32,
        stream_id.to_i64, payload)
      select
      when @writes.send(op)
        # queued
      else
        @h2_frames_dropped.add(1) # writer saturated — drop the raw frame, keep the flow
      end
    rescue Channel::ClosedError
      # store closing (Store#close closed @writes) — drop the late frame instead of
      # raising on the relay fiber mid-shutdown
    end

    # The connection's raw frame log. With `limit`, returns the MOST RECENT `limit`
    # frames (still ascending for display) so the detail view can bound memory on a
    # pathological connection — the caller shows a count-based "older not loaded"
    # note (see count_h2_frames). nil limit = all (the prior behaviour).
    def h2_frames(conn_id : Int64, limit : Int32? = nil) : Array(H2Frame)
      list = [] of H2Frame
      cols = "id, conn_id, created_at, direction, stream_id, type, flags, length, payload"
      q, args = if lim = limit
                  {"SELECT * FROM (SELECT #{cols} FROM h2_frames WHERE conn_id = ? ORDER BY id DESC LIMIT ?) ORDER BY id",
                   [conn_id, lim.to_i64] of DB::Any}
                else
                  {"SELECT #{cols} FROM h2_frames WHERE conn_id = ? ORDER BY id", [conn_id] of DB::Any}
                end
      @db.query(q, args: args) do |rs|
        rs.each do
          list << H2Frame.new(
            rs.read(Int64), rs.read(Int64), rs.read(Int64), rs.read(String),
            rs.read(Int64), rs.read(Int32), rs.read(Int32), rs.read(Int32), rs.read(Bytes))
        end
      end
      list
    end

    def count_h2_frames(conn_id : Int64) : Int32
      @db.scalar("SELECT COUNT(*) FROM h2_frames WHERE conn_id = ?", conn_id).as(Int64).to_i
    end

    # The column list every `ws_messages` read shares, ending with the six V7 shape columns
    # in `Store.read_ws_shape`'s order. It was spelled out three times, and a fourth omission
    # here is how a reader silently starts handing back `Shape::DEFAULT` for a frame that had
    # RSV1 set.
    WS_MESSAGE_COLS = "id, flow_id, repeater_id, created_at, direction, opcode, payload, " \
                      "fin, rsv, masked, mask_key, frames, declared_len"

    private def read_ws_messages(q : String, args : Array(DB::Any)) : Array(WsMessage)
      msgs = [] of WsMessage
      @db.query(q, args: args) do |rs|
        rs.each do
          msgs << WsMessage.new(rs.read(Int64), rs.read(Int64), rs.read(Int64?), rs.read(Int64),
            rs.read(String), rs.read(Int32), rs.read(Bytes), Store.read_ws_shape(rs))
        end
      end
      msgs
    end

    # The flow's captured WS message log. With `limit`, returns the MOST RECENT
    # `limit` messages (ascending for display) to bound the detail view; nil = all.
    def ws_messages(flow_id : Int64, limit : Int32? = nil) : Array(WsMessage)
      cols = WS_MESSAGE_COLS
      q, args = if lim = limit
                  {"SELECT * FROM (SELECT #{cols} FROM ws_messages WHERE flow_id = ? ORDER BY id DESC LIMIT ?) ORDER BY id",
                   [flow_id, lim.to_i64] of DB::Any}
                else
                  {"SELECT #{cols} FROM ws_messages WHERE flow_id = ? ORDER BY id", [flow_id] of DB::Any}
                end
      read_ws_messages(q, args)
    end

    # Frames on a flow with id AFTER `after_id`, OLDEST-first, up to `limit`. Lets the Probe WS
    # rescan page forward from its per-flow high-water-mark and cover every frame exactly once,
    # even when more than a full window accumulated unscanned (a dropped-event burst) or the flow
    # was evicted from the analyzed-set and re-scanned.
    def ws_messages_after(flow_id : Int64, after_id : Int64, limit : Int32) : Array(WsMessage)
      read_ws_messages(
        "SELECT #{WS_MESSAGE_COLS} FROM ws_messages WHERE flow_id = ? AND id > ? ORDER BY id LIMIT ?",
        [flow_id, after_id, limit.to_i64] of DB::Any)
    end

    # Frames on a REPEATER tab with id AFTER `after_id`, OLDEST-first, up to `limit` — the
    # repeater twin of `ws_messages_after`, and it exists for the same reason. The limited form
    # of `ws_messages_for_repeater` below returns the NEWEST `limit` rows (that bound is for the
    # detail VIEW), so the headless probe scan, which asked for 200, read only the tail of a
    # transcript a WS repeater script can fill to `WsEngine::MAX_RECV_MESSAGES` — a secret in
    # frame 20 of 900 was reported for the same socket captured by the proxy and missed here.
    def ws_messages_for_repeater_after(repeater_id : Int64, after_id : Int64, limit : Int32) : Array(WsMessage)
      read_ws_messages(
        "SELECT #{WS_MESSAGE_COLS} FROM ws_messages WHERE repeater_id = ? AND id > ? ORDER BY id LIMIT ?",
        [repeater_id, after_id, limit.to_i64] of DB::Any)
    end

    def ws_messages_for_repeater(repeater_id : Int64, limit : Int32? = nil) : Array(WsMessage)
      cols = WS_MESSAGE_COLS
      q, args = if lim = limit
                  {"SELECT * FROM (SELECT #{cols} FROM ws_messages WHERE repeater_id = ? ORDER BY id DESC LIMIT ?) ORDER BY id",
                   [repeater_id, lim.to_i64] of DB::Any}
                else
                  {"SELECT #{cols} FROM ws_messages WHERE repeater_id = ? ORDER BY id", [repeater_id] of DB::Any}
                end
      read_ws_messages(q, args)
    end

    def count_ws_messages(flow_id : Int64) : Int32
      @db.scalar("SELECT COUNT(*) FROM ws_messages WHERE flow_id = ?", flow_id).as(Int64).to_i
    end
  end
end
