require "db"

module Gori
  class Store
    # --- miner sessions (mirror fuzz_sessions; request is a byte-exact BLOB) ---

    def miner_sessions : Array(MinerSessionRecord)
      list = [] of MinerSessionRecord
      @db.query("SELECT id, target, request, http2, sni, config, flow_id, position, name FROM miner_sessions ORDER BY position, id") do |rs|
        rs.each do
          list << MinerSessionRecord.new(
            rs.read(Int64), rs.read(String), rs.read(Bytes), rs.read(Int32) != 0,
            rs.read(String?), rs.read(String), rs.read(Int64?), rs.read(Int32), rs.read(String?))
        end
      end
      list
    end

    def get_miner_session(id : Int64) : MinerSessionRecord?
      @db.query(
        "SELECT id, target, request, http2, sni, config, flow_id, position, name FROM miner_sessions WHERE id = ?",
        id) do |rs|
        return MinerSessionRecord.new(
          rs.read(Int64), rs.read(String), rs.read(Bytes), rs.read(Int32) != 0,
          rs.read(String?), rs.read(String), rs.read(Int64?), rs.read(Int32), rs.read(String?)) if rs.move_next
      end
      nil
    end

    def insert_miner_session(target : String, request : Bytes, http2 : Bool, sni : String?,
                             config : String, flow_id : Int64?, position : Int32, name : String? = nil) : Int64
      ts = now_us
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO miner_sessions (created_at, updated_at, target, request, http2, sni, config, flow_id, position, name) VALUES (?,?,?,?,?,?,?,?,?,?)",
          ts, ts, target, request, http2 ? 1 : 0, sni, config, flow_id, position, name)
        nil
      }
    end

    def update_miner_session(id : Int64, target : String, request : Bytes, http2 : Bool,
                             sni : String?, config : String, name : String? = nil) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE miner_sessions SET target=?, request=?, http2=?, sni=?, config=?, name=?, updated_at=? WHERE id=?",
          target, request, http2 ? 1 : 0, sni, config, name, now_us, id)
        nil
      }
    end

    # Set (or clear, with nil) a miner session's custom sub-tab name — its own UPDATE so a
    # rename never rewrites the request/config (mirrors set_fuzz_session_name).
    def set_miner_session_name(id : Int64, name : String?) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE miner_sessions SET name = ?, updated_at = ? WHERE id = ?", name, now_us, id)
        nil
      }
    end

    # Cascades `entity_links`, same as `delete_fuzz_session` and for the same reason
    # (`delete_repeater` states it in full): `miner_sessions.id` is `INTEGER PRIMARY KEY`
    # without AUTOINCREMENT and a ^W closes the NEWEST tab, so the id comes straight back and
    # a surviving link re-binds — silently — to a session against another target instead of
    # reading `miner #N (gone)`. One exec_task for both statements so a rollback can never
    # strand the link, and the predicate carries ref_kind because ids collide across kinds.
    def delete_miner_session(id : Int64) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("DELETE FROM entity_links WHERE ref_kind = 'miner' AND ref_id = ?", id)
        c.exec("DELETE FROM miner_sessions WHERE id = ?", id)
        nil
      }
    end
  end
end
