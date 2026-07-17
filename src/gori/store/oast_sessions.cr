require "db"

module Gori
  class Store
    # ---- OAST (out-of-band) providers / sessions / callbacks (V40) ----

    def oast_providers : Array(OastProviderRecord)
      list = [] of OastProviderRecord
      @db.query("SELECT id, name, kind, host, token, enabled, position FROM oast_providers ORDER BY position, id") do |rs|
        rs.each do
          list << OastProviderRecord.new(
            rs.read(Int64), rs.read(String), rs.read(String), rs.read(String),
            rs.read(String?), rs.read(Int32) != 0, rs.read(Int32))
        end
      end
      list
    end

    def insert_oast_provider(name : String, kind : String, host : String, token : String?,
                             enabled : Bool, position : Int32) : Int64
      ts = now_us
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO oast_providers (created_at, updated_at, name, kind, host, token, enabled, position) VALUES (?,?,?,?,?,?,?,?)",
          ts, ts, name, kind, host, token, enabled ? 1 : 0, position)
        nil
      }
    end

    def update_oast_provider(id : Int64, name : String, kind : String, host : String,
                             token : String?, enabled : Bool) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE oast_providers SET name=?, kind=?, host=?, token=?, enabled=?, updated_at=? WHERE id=?",
          name, kind, host, token, enabled ? 1 : 0, now_us, id)
        nil
      }
    end

    def set_oast_provider_enabled(id : Int64, enabled : Bool) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE oast_providers SET enabled=?, updated_at=? WHERE id=?", enabled ? 1 : 0, now_us, id)
        nil
      }
    end

    def delete_oast_provider(id : Int64) : Nil
      exec_task ->(c : DB::Connection) { c.exec("DELETE FROM oast_providers WHERE id = ?", id); nil }
    end

    def oast_sessions : Array(OastSessionRecord)
      list = [] of OastSessionRecord
      @db.query("SELECT id, provider_id, kind, server_url, correlation_id, secret, private_key_pem, token, last_poll_at FROM oast_sessions ORDER BY id") do |rs|
        rs.each { list << read_oast_session(rs) }
      end
      list
    end

    def get_oast_session(id : Int64) : OastSessionRecord?
      @db.query("SELECT id, provider_id, kind, server_url, correlation_id, secret, private_key_pem, token, last_poll_at FROM oast_sessions WHERE id = ?", id) do |rs|
        return read_oast_session(rs) if rs.move_next
      end
      nil
    end

    def insert_oast_session(provider_id : Int64?, kind : String, server_url : String,
                            correlation_id : String, secret : String, private_key_pem : String?,
                            token : String?) : Int64
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO oast_sessions (created_at, provider_id, kind, server_url, correlation_id, secret, private_key_pem, token) VALUES (?,?,?,?,?,?,?,?)",
          now_us, provider_id, kind, server_url, correlation_id, secret, private_key_pem, token)
        nil
      }
    end

    def touch_oast_session(id : Int64, last_poll_at : Int64) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE oast_sessions SET last_poll_at=? WHERE id=?", last_poll_at, id)
        nil
      }
    end

    def delete_oast_session(id : Int64) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("DELETE FROM oast_callbacks WHERE session_id = ?", id)
        c.exec("DELETE FROM oast_sessions WHERE id = ?", id)
        nil
      }
    end

    # Incremental (watermark) load: callbacks with id > since_id, oldest first. Callbacks are
    # append-only, so the caller keeps @max_seen_id and never re-selects the whole table.
    def oast_callbacks(session_id : Int64, since_id : Int64 = 0) : Array(OastCallbackRecord)
      list = [] of OastCallbackRecord
      @db.query("SELECT id, session_id, created_at, provider_uid, protocol, method, source_ip, full_id, raw_request, raw_response FROM oast_callbacks WHERE session_id = ? AND id > ? ORDER BY id", session_id, since_id) do |rs|
        rs.each do
          list << OastCallbackRecord.new(
            rs.read(Int64), rs.read(Int64), rs.read(Int64), rs.read(String), rs.read(String),
            rs.read(String?), rs.read(String?), rs.read(String), rs.read(Bytes), rs.read(Bytes?))
        end
      end
      list
    end

    # INSERT OR IGNORE on the UNIQUE(session_id, provider_uid) dedup key. The DB enforces
    # dedup; the return (last_insert_rowid) is NOT a reliable new-vs-ignored signal, so the
    # controller dedups in memory (a seen-uid set) and treats this as a durable backstop.
    def insert_oast_callback(session_id : Int64, provider_uid : String, protocol : String,
                             method : String?, source_ip : String?, full_id : String,
                             raw_request : Bytes, raw_response : Bytes?, created_at : Int64) : Int64
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT OR IGNORE INTO oast_callbacks (session_id, created_at, provider_uid, protocol, method, source_ip, full_id, raw_request, raw_response) VALUES (?,?,?,?,?,?,?,?,?)",
          session_id, created_at, provider_uid, protocol, method, source_ip, full_id, raw_request, raw_response)
        nil
      }
    end

    private def read_oast_session(rs : DB::ResultSet) : OastSessionRecord
      OastSessionRecord.new(
        rs.read(Int64), rs.read(Int64?), rs.read(String), rs.read(String), rs.read(String),
        rs.read(String), rs.read(String?), rs.read(String?), rs.read(Int64?))
    end
  end
end
