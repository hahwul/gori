require "db"

module Gori
  class Store
    # --- sequencer sessions (mirror miner_sessions; request is a byte-exact BLOB) ---

    def sequencer_sessions : Array(SequencerSessionRecord)
      list = [] of SequencerSessionRecord
      @db.query("SELECT id, target, request, http2, sni, config, flow_id, position, name FROM sequencer_sessions ORDER BY position, id") do |rs|
        rs.each do
          list << SequencerSessionRecord.new(
            rs.read(Int64), rs.read(String), rs.read(Bytes), rs.read(Int32) != 0,
            rs.read(String?), rs.read(String), rs.read(Int64?), rs.read(Int32), rs.read(String?))
        end
      end
      list
    end

    def get_sequencer_session(id : Int64) : SequencerSessionRecord?
      @db.query(
        "SELECT id, target, request, http2, sni, config, flow_id, position, name FROM sequencer_sessions WHERE id = ?",
        id) do |rs|
        return SequencerSessionRecord.new(
          rs.read(Int64), rs.read(String), rs.read(Bytes), rs.read(Int32) != 0,
          rs.read(String?), rs.read(String), rs.read(Int64?), rs.read(Int32), rs.read(String?)) if rs.move_next
      end
      nil
    end

    def insert_sequencer_session(target : String, request : Bytes, http2 : Bool, sni : String?,
                                 config : String, flow_id : Int64?, position : Int32, name : String? = nil) : Int64
      ts = now_us
      exec_task ->(c : DB::Connection) {
        # `request` goes through `Store.blob_slot`: the column is `BLOB NOT NULL`, and an empty
        # slice binds SQL NULL, which violated it and rolled back the whole writer batch —
        # silently, since this returns 0 for "dropped" and the caller reads that as "no session".
        args = [ts, ts, target] of DB::Any
        slot = Store.blob_slot(args, request)
        args << (http2 ? 1 : 0) << sni << config << flow_id << position << name
        c.exec("INSERT INTO sequencer_sessions (created_at, updated_at, target, request, http2, sni, config, flow_id, position, name) " \
               "VALUES (?,?,?,#{slot},?,?,?,?,?,?)", args: args)
        nil
      }
    end

    def update_sequencer_session(id : Int64, target : String, request : Bytes, http2 : Bool,
                                 sni : String?, config : String, name : String? = nil) : Nil
      exec_task ->(c : DB::Connection) {
        args = [target] of DB::Any
        slot = Store.blob_slot(args, request) # BLOB NOT NULL — see the insert above
        args << (http2 ? 1 : 0) << sni << config << name << now_us << id
        c.exec("UPDATE sequencer_sessions SET target=?, request=#{slot}, http2=?, sni=?, config=?, name=?, updated_at=? WHERE id=?", args: args)
        nil
      }
    end

    # Set (or clear, with nil) a sequencer session's custom sub-tab name — its own UPDATE
    # so a rename never rewrites the request/config (mirrors set_miner_session_name).
    #
    # Returns whether the write committed (false = store busy/locked/closing), for
    # `set_fuzz_session_name`'s reason: `exec_task`'s `last_insert_rowid` reply says nothing
    # about an UPDATE, so `SequencerController#apply_rename` — which has already set the label
    # on the view — could not tell a commit from a rolled-back batch and told the operator nothing.
    def set_sequencer_session_name(id : Int64, name : String?) : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("UPDATE sequencer_sessions SET name = ?, updated_at = ? WHERE id = ?", name, now_us, id)
        nil
      }
    end

    # Cascades `entity_links` PRE-EMPTIVELY. Unlike the fuzz/miner siblings this fixes nothing
    # today: `LinkRefKind` has no `Sequencer` variant, so `parse` accepts only
    # flow|repeater|fuzz|miner and no link can name a sequencer session — the DELETE below
    # matches zero rows by construction. It is here because this delete was the last one in the
    # family written the way fuzz's and miner's were, and those two shipped a real bug (#574):
    # an uncascaded link outlives its session, and because `id` is `INTEGER PRIMARY KEY`
    # without AUTOINCREMENT the next insert reuses the id and the stray link silently re-binds
    # to a different target.
    #
    # So, for whoever adds a `Sequencer` variant to `LinkRefKind`: this line already covers the
    # delete path, but the OTHER half is missing. `sequencer_sessions` was deliberately left
    # out of the V10 rebuild that gave fuzz/miner `AUTOINCREMENT` (there was no id to protect),
    # and it needs its own migration on that day — otherwise reuse makes a stray dangerous
    # rather than merely dead. See the V10 comment in schema.cr for the shape.
    # Returns whether the delete COMMITTED, like `delete_repeater` and `delete_fuzz_session`: a
    # rolled-back batch leaves the row, so the tab the operator closed reappears on the next open.
    def delete_sequencer_session(id : Int64) : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("DELETE FROM entity_links WHERE ref_kind = 'sequencer' AND ref_id = ?", id)
        c.exec("DELETE FROM sequencer_sessions WHERE id = ?", id)
        nil
      }
    end
  end
end
