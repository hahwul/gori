require "db"

module Gori
  class Store
    # --- Fuzzer / Intruder (V16) ---------------------------------------------
    # Writes go through exec_task (writer fiber). Own commits bump data_version on
    # the read pool (see data_version docs); live TUI paths must soft-sync, not
    # full-restore session UI on every poll.

    def fuzz_sessions : Array(FuzzSessionRecord)
      list = [] of FuzzSessionRecord
      @db.query("SELECT id, target, template, http2, sni, config, flow_id, position, name FROM fuzz_sessions ORDER BY position, id") do |rs|
        rs.each do
          list << FuzzSessionRecord.new(
            rs.read(Int64), rs.read(String), rs.read(String), rs.read(Int32) != 0,
            rs.read(String?), rs.read(String), rs.read(Int64?), rs.read(Int32), rs.read(String?))
        end
      end
      list
    end

    def get_fuzz_session(id : Int64) : FuzzSessionRecord?
      @db.query(
        "SELECT id, target, template, http2, sni, config, flow_id, position, name FROM fuzz_sessions WHERE id = ?",
        id) do |rs|
        return FuzzSessionRecord.new(
          rs.read(Int64), rs.read(String), rs.read(String), rs.read(Int32) != 0,
          rs.read(String?), rs.read(String), rs.read(Int64?), rs.read(Int32), rs.read(String?)) if rs.move_next
      end
      nil
    end

    def insert_fuzz_session(target : String, template : String, http2 : Bool, sni : String?,
                            config : String, flow_id : Int64?, position : Int32, name : String? = nil) : Int64
      ts = now_us
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO fuzz_sessions (created_at, updated_at, target, template, http2, sni, config, flow_id, position, name) VALUES (?,?,?,?,?,?,?,?,?,?)",
          ts, ts, target, template, http2 ? 1 : 0, sni, config, flow_id, position, name)
        nil
      }
    end

    def update_fuzz_session(id : Int64, target : String, template : String, http2 : Bool,
                            sni : String?, config : String, name : String? = nil) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE fuzz_sessions SET target=?, template=?, http2=?, sni=?, config=?, name=?, updated_at=? WHERE id=?",
          target, template, http2 ? 1 : 0, sni, config, name, now_us, id)
        nil
      }
    end

    # Set (or clear, with nil) a fuzz session's custom sub-tab name — its own UPDATE,
    # separate from update_fuzz_session so a rename never rewrites the template/config
    # (mirrors set_repeater_name).
    def set_fuzz_session_name(id : Int64, name : String?) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE fuzz_sessions SET name = ?, updated_at = ? WHERE id = ?", name, now_us, id)
        nil
      }
    end

    def delete_fuzz_session(id : Int64) : Nil
      exec_task ->(c : DB::Connection) { c.exec("DELETE FROM fuzz_sessions WHERE id = ?", id); nil }
    end
  end
end
