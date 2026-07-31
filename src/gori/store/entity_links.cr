require "db"

module Gori
  class Store
    # --- entity links (V21) --------------------------------------------------

    # Insert a link; returns the row id, or nil when the link already exists.
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
      exec_task ->(c : DB::Connection) {
        refs.each do |(ref_kind, ref_id)|
          c.exec(
            "INSERT OR IGNORE INTO entity_links (owner_kind, owner_id, ref_kind, ref_id, created_at) VALUES (?,?,?,?,?)",
            owner_kind.label, owner_id, ref_kind.label, ref_id, ts)
          inserted += c.scalar("SELECT changes()").as(Int64).to_i
        end
        nil
      }
      inserted
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

    # `exec_task_ok`: the store answers whether the write COMMITTED, and dropping that made
    # every caller report the change for a rolled-back batch. Same conversion as `delete_flows`
    # (`reads.cr`), whose comment states the reasoning once.
    def remove_link(id : Int64) : Bool
      exec_task_ok ->(c : DB::Connection) { c.exec("DELETE FROM entity_links WHERE id = ?", id); nil }
    end

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
