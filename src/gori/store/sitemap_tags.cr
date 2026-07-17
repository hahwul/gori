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

    # Upsert a node's tag; a blank tag clears it (DELETE) so the row never lingers empty.
    def set_sitemap_tag(host : String, path : String, tag : String) : Nil
      exec_task ->(c : DB::Connection) {
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
