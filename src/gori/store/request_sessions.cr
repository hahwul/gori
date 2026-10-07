require "db"

module Gori
  class Store
    # --- miner and sequencer sessions (mirror fuzz_sessions; request is a byte-exact BLOB) ---
    #
    # `miner_sessions` and `sequencer_sessions` have the same columns and the same contract, so
    # one implementation serves both. `kind` is "miner" or "sequencer": it names the table and
    # the `entity_links.ref_kind`. The macro at the bottom spells each kind's public methods:
    # `miner_sessions`, `get_miner_session`, `insert_miner_session`, `update_miner_session`,
    # `set_miner_session_name`, `delete_miner_session`, and the same six for `sequencer`.

    private def request_sessions(kind : String) : Array(RequestSessionRecord)
      list = [] of RequestSessionRecord
      @db.query("SELECT id, target, request, http2, sni, config, flow_id, position, name FROM #{kind}_sessions ORDER BY position, id") do |rs|
        rs.each do
          list << read_request_session(rs)
        end
      end
      list
    end

    private def get_request_session(kind : String, id : Int64) : RequestSessionRecord?
      @db.query(
        "SELECT id, target, request, http2, sni, config, flow_id, position, name FROM #{kind}_sessions WHERE id = ?",
        id) do |rs|
        return read_request_session(rs) if rs.move_next
      end
      nil
    end

    private def read_request_session(rs : DB::ResultSet) : RequestSessionRecord
      RequestSessionRecord.new(
        rs.read(Int64), rs.read(String), rs.read(Bytes), rs.read(Int32) != 0,
        rs.read(String?), rs.read(String), rs.read(Int64?), rs.read(Int32), rs.read(String?))
    end

    private def insert_request_session(kind : String, target : String, request : Bytes, http2 : Bool, sni : String?,
                                       config : String, flow_id : Int64?, position : Int32, name : String?) : Int64
      ts = now_us
      exec_task ->(c : DB::Connection) {
        # `request` goes through `Store.blob_slot`: the column is `BLOB NOT NULL`, and an empty
        # slice binds SQL NULL, which violated it and rolled back the whole writer batch —
        # silently, since this returns 0 for "dropped" and the caller reads that as "no session".
        args = [ts, ts, target] of DB::Any
        slot = Store.blob_slot(args, request)
        args << (http2 ? 1 : 0) << sni << config << flow_id << position << name
        c.exec("INSERT INTO #{kind}_sessions (created_at, updated_at, target, request, http2, sni, config, flow_id, position, name) " \
               "VALUES (?,?,?,#{slot},?,?,?,?,?,?)", args: args)
        nil
      }
    end

    private def update_request_session(kind : String, id : Int64, target : String, request : Bytes, http2 : Bool,
                                       sni : String?, config : String, name : String?) : Nil
      exec_task ->(c : DB::Connection) {
        args = [target] of DB::Any
        slot = Store.blob_slot(args, request) # BLOB NOT NULL — see the insert above
        args << (http2 ? 1 : 0) << sni << config << name << now_us << id
        c.exec("UPDATE #{kind}_sessions SET target=?, request=#{slot}, http2=?, sni=?, config=?, name=?, updated_at=? WHERE id=?", args: args)
        nil
      }
    end

    # Set (or clear, with nil) a session's custom sub-tab name — its own UPDATE so a rename
    # never rewrites the request/config (mirrors set_fuzz_session_name).
    #
    # Returns whether the write committed (false = store busy/locked/closing), for
    # `set_fuzz_session_name`'s reason: `exec_task`'s `last_insert_rowid` reply says nothing
    # about an UPDATE, so `MinerController#apply_rename` — which has already set the label on
    # the view — could not tell a commit from a rolled-back batch and told the operator nothing.
    private def set_request_session_name(kind : String, id : Int64, name : String?) : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("UPDATE #{kind}_sessions SET name = ?, updated_at = ? WHERE id = ?", name, now_us, id)
        nil
      }
    end

    # Cascades `entity_links`, same as `delete_fuzz_session` and for the same reason
    # (`delete_repeater` states it in full): an uncascaded link outlived its session (#574) and
    # read as live instead of `miner #N (gone)`. For sequencer the cascade is PRE-EMPTIVE:
    # `LinkRefKind` has no `Sequencer` variant, so no link can name a sequencer session and the
    # DELETE matches zero rows by construction. One exec_task for both statements so a rollback
    # can never strand the link, and the predicate carries ref_kind because ids collide across
    # kinds.
    #
    # Both ids are AUTOINCREMENT (miner since V10, sequencer since V41), so a deleted id is never
    # handed out again: a peer TUI still holding this session's tab, or an Activity row pointing
    # at it, finds it gone instead of adopting the next session created.
    # Returns whether the delete COMMITTED, like `delete_repeater` and `delete_fuzz_session`: a
    # rolled-back batch leaves the row, so the tab the operator closed reappears on the next open.
    private def delete_request_session(kind : String, id : Int64) : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("DELETE FROM entity_links WHERE ref_kind = ? AND ref_id = ?", kind, id)
        c.exec("DELETE FROM #{kind}_sessions WHERE id = ?", id)
        nil
      }
    end

    def miner_sessions : Array(RequestSessionRecord)
      request_sessions("miner")
    end

    def get_miner_session(id : Int64) : RequestSessionRecord?
      get_request_session("miner", id)
    end

    def insert_miner_session(target : String, request : Bytes, http2 : Bool, sni : String?,
                             config : String, flow_id : Int64?, position : Int32, name : String? = nil) : Int64
      insert_request_session("miner", target, request, http2, sni, config, flow_id, position, name)
    end

    def update_miner_session(id : Int64, target : String, request : Bytes, http2 : Bool,
                             sni : String?, config : String, name : String? = nil) : Nil
      update_request_session("miner", id, target, request, http2, sni, config, name)
    end

    def set_miner_session_name(id : Int64, name : String?) : Bool
      set_request_session_name("miner", id, name)
    end

    def delete_miner_session(id : Int64) : Bool
      delete_request_session("miner", id)
    end

    def sequencer_sessions : Array(RequestSessionRecord)
      request_sessions("sequencer")
    end

    def insert_sequencer_session(target : String, request : Bytes, http2 : Bool, sni : String?,
                                 config : String, flow_id : Int64?, position : Int32, name : String? = nil) : Int64
      insert_request_session("sequencer", target, request, http2, sni, config, flow_id, position, name)
    end

    def update_sequencer_session(id : Int64, target : String, request : Bytes, http2 : Bool,
                                 sni : String?, config : String, name : String? = nil) : Nil
      update_request_session("sequencer", id, target, request, http2, sni, config, name)
    end

    def set_sequencer_session_name(id : Int64, name : String?) : Bool
      set_request_session_name("sequencer", id, name)
    end

    def delete_sequencer_session(id : Int64) : Bool
      delete_request_session("sequencer", id)
    end
  end
end
