require "db"

module Gori
  class Store
    # --- entity links (V21) --------------------------------------------------

    # Insert a link; returns the row id, or nil when no row was inserted: the link already
    # exists OR the write did not commit (busy/locked/closing). A caller that reports the
    # difference asks `link_id` — a row means "already linked", none means "not added".
    def add_link(owner_kind : LinkOwnerKind, owner_id : Int64, ref_kind : LinkRefKind, ref_id : Int64) : Int64?
      ts = now_us
      exec_task ->(c : DB::Connection) {
        c.exec(
          "INSERT OR IGNORE INTO entity_links (owner_kind, owner_id, ref_kind, ref_id, created_at) VALUES (?,?,?,?,?)",
          owner_kind.label, owner_id, ref_kind.label, ref_id, ts)
        nil
      }
      @db.query(
        "SELECT id, created_at FROM entity_links WHERE owner_kind = ? AND owner_id = ? AND ref_kind = ? AND ref_id = ?",
        owner_kind.label, owner_id, ref_kind.label, ref_id) do |rs|
        return nil unless rs.move_next
        id = rs.read(Int64)
        created_at = rs.read(Int64)
        return id if created_at == ts
      end
      nil
    end

    # Attach MANY refs to one owner — History's multi-select link (#442). Returns how many rows
    # were actually inserted (the rest were already linked).
    #
    # One exec_task for the whole set, like delete_flows: add_link is a separate transaction plus
    # a SELECT per call, and exec_task BLOCKS the calling fiber on its reply, so looping it over a
    # marked set would stall the single-threaded render loop for one write-batch round-trip per
    # flow — seconds at typical fsync latency once ⇧T has marked a page. The inserted count comes
    # from `changes()` inside the same transaction, so no follow-up read is needed either.
    def add_links(owner_kind : LinkOwnerKind, owner_id : Int64, refs : Array({LinkRefKind, Int64})) : Int32
      return 0 if refs.empty?
      ts = now_us
      inserted = 0
      # exec_task_ok, not exec_task: the tally accumulates inside the transaction, so a
      # batch that later rolls back still produced a nonzero count and the caller toasted
      # "linked N" for rows that never committed. (exec_task's own Int64 reply cannot
      # stand in — on a committed batch where every INSERT OR IGNORE was ignored,
      # last_insert_rowid is a stale nonzero, so it can't discriminate either.)
      ok = exec_task_ok ->(c : DB::Connection) {
        refs.each do |(ref_kind, ref_id)|
          c.exec(
            "INSERT OR IGNORE INTO entity_links (owner_kind, owner_id, ref_kind, ref_id, created_at) VALUES (?,?,?,?,?)",
            owner_kind.label, owner_id, ref_kind.label, ref_id, ts)
          inserted += c.scalar("SELECT changes()").as(Int64).to_i
        end
        nil
      }
      ok ? inserted : 0
    end

    def link_id(owner_kind : LinkOwnerKind, owner_id : Int64, ref_kind : LinkRefKind, ref_id : Int64) : Int64?
      @db.query(
        "SELECT id FROM entity_links WHERE owner_kind = ? AND owner_id = ? AND ref_kind = ? AND ref_id = ?",
        owner_kind.label, owner_id, ref_kind.label, ref_id) do |rs|
        return rs.read(Int64) if rs.move_next
      end
      nil
    end

    def list_links(owner_kind : LinkOwnerKind, owner_id : Int64) : Array(EntityLink)
      list = [] of EntityLink
      @db.query(
        "SELECT id, owner_kind, owner_id, ref_kind, ref_id, created_at FROM entity_links " \
        "WHERE owner_kind = ? AND owner_id = ? ORDER BY created_at, id",
        owner_kind.label, owner_id) do |rs|
        rs.each { try_read_entity_link(rs).try { |link| list << link } }
      end
      list
    end

    # Does ANY owner already link this ref? The ref side of `list_links`, and the only thing
    # asked of it so far is a Bool: the link picker opens on `+ New issue…` for a ref nobody
    # has filed yet and on the first existing owner otherwise, which is the common first
    # filing made two keystrokes shorter.
    #
    # A scan rather than an index seek — `idx_entity_links_owner` and the UNIQUE constraint
    # are both owner-first, and this table holds links, not flows. It runs once when a card
    # opens, which is not a price worth a migration.
    def ref_linked?(ref_kind : LinkRefKind, ref_id : Int64) : Bool
      @db.query("SELECT 1 FROM entity_links WHERE ref_kind = ? AND ref_id = ? LIMIT 1",
        ref_kind.label, ref_id) do |rs|
        return true if rs.move_next
      end
      false
    end

    # Does the row a link would point at exist? Asked before a link is filed, so a pointer to
    # nothing is refused rather than stored and later listed as stale. Each kind is checked
    # against its own table: a flow id is not a repeater id.
    #
    # `flow_row` / `get_*_session` are the row-only reads; `get_flow` would materialize the
    # request AND response BLOBs just to answer "does this exist?".
    def link_ref_exists?(kind : LinkRefKind, id : Int64) : Bool
      case kind
      when .flow?     then !flow_row(id).nil?
      when .repeater? then !get_repeater(id).nil?
      when .fuzz?     then !get_fuzz_session(id).nil?
      else                 !get_miner_session(id).nil?
      end
    end

    # `exec_task_ok`: the store answers whether the write COMMITTED, and dropping that made
    # every caller report the change for a rolled-back batch. Same conversion as `delete_flows`
    # (`reads.cr`), whose comment states the reasoning once.
    def remove_link(owner_kind : LinkOwnerKind, owner_id : Int64, ref_kind : LinkRefKind, ref_id : Int64) : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec(
          "DELETE FROM entity_links WHERE owner_kind = ? AND owner_id = ? AND ref_kind = ? AND ref_id = ?",
          owner_kind.label, owner_id, ref_kind.label, ref_id)
        nil
      }
    end

    def delete_links_for_owner(owner_kind : LinkOwnerKind, owner_id : Int64) : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("DELETE FROM entity_links WHERE owner_kind = ? AND owner_id = ?", owner_kind.label, owner_id)
        nil
      }
    end
  end
end
