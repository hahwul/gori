require "db"

module Gori
  class Store
    # --- sitemap tags (V17) --------------------------------------------------

    # All path tags as a (host, path) ⇒ tag map, loaded once per Sitemap reload so the
    # tree stamp is an O(1) hash lookup per node (not a query per row).
    def sitemap_tags : Hash({String, String}, String)
      tags = Hash({String, String}, String).new
      @db.query("SELECT host, path, tag FROM sitemap_tags") do |rs|
        rs.each { tags[{rs.read(String), rs.read(String)}] = rs.read(String) }
      end
      tags
    rescue
      Hash({String, String}, String).new # never crash the run loop over a read (mirrors sitemap_entries)
    end

    # Whether any captured endpoint on `host` lands on the tag key `path` — the derivation the
    # tree's tag stamping uses (`Sitemap.tag_path`), so "matched" means "will be visible there".
    # A tag whose (host, path) names no endpoint is stored but unreachable; the common causes
    # are a typo and a trailing slash.
    #
    # `nil` means UNKNOWN, and the distinction is load-bearing: the scan is capped at
    # SITEMAP_MAX, and that cap is on the 6-column transport key, which multiplies past 10k
    # long before the collapsed host/method/target count suggests. Answering a flat `false`
    # off a truncated read made a positive claim about the capture that the query could not
    # support — and the warning built on it told the operator to go hunting for a typo in a
    # tag that was stored and does show.
    def sitemap_node_exists?(host : String, path : String) : Bool?
      entries = sitemap_entries_detailed(QL::EMPTY, SITEMAP_MAX)
      return true if entries.any? { |e| e.host == host && Sitemap.tag_path(e.target) == path }
      entries.size >= SITEMAP_MAX ? nil : false
    end

    # Upsert a node's tag; a blank tag clears it (DELETE) so the row never lingers empty.
    # `exec_task_ok`: the store answers whether the write COMMITTED, and dropping that made
    # every caller report the change for a rolled-back batch. Same conversion as `delete_flows`
    # (`reads.cr`), whose comment states the reasoning once.
    def set_sitemap_tag(host : String, path : String, tag : String) : Bool
      exec_task_ok ->(c : DB::Connection) {
        if tag.blank?
          c.exec("DELETE FROM sitemap_tags WHERE host = ? AND path = ?", host, path)
        else
          c.exec("INSERT INTO sitemap_tags (host, path, tag) VALUES (?, ?, ?) " \
                 "ON CONFLICT(host, path) DO UPDATE SET tag = ?", host, path, tag, tag)
        end
        nil
      }
    end
  end
end
