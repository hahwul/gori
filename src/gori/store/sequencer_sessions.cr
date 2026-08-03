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
        c.exec("INSERT INTO sequencer_sessions (created_at, updated_at, target, request, http2, sni, config, flow_id, position, name) VALUES (?,?,?,?,?,?,?,?,?,?)",
          ts, ts, target, request, http2 ? 1 : 0, sni, config, flow_id, position, name)
        nil
      }
    end

    def update_sequencer_session(id : Int64, target : String, request : Bytes, http2 : Bool,
                                 sni : String?, config : String, name : String? = nil) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE sequencer_sessions SET target=?, request=?, http2=?, sni=?, config=?, name=?, updated_at=? WHERE id=?",
          target, request, http2 ? 1 : 0, sni, config, name, now_us, id)
        nil
      }
    end

    # Set (or clear, with nil) a sequencer session's custom sub-tab name — its own UPDATE
    # so a rename never rewrites the request/config (mirrors set_miner_session_name).
    def set_sequencer_session_name(id : Int64, name : String?) : Nil
      exec_task ->(c : DB::Connection) {
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
    def delete_sequencer_session(id : Int64) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("DELETE FROM entity_links WHERE ref_kind = 'sequencer' AND ref_id = ?", id)
        c.exec("DELETE FROM sequencer_sessions WHERE id = ?", id)
        nil
      }
    end
  end
end
