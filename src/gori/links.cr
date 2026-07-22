require "./store"

module Gori
  # Resolves `entity_links` rows into human-readable labels/URLs for the TUI and export.
  module Links
    struct Resolved
      getter link : Store::EntityLink
      getter tag : String   # short kind tag, e.g. "hist"
      getter label : String # primary line (method + path, session name, …)
      getter url : String   # absolute URL or best-effort location string
      getter? stale : Bool  # true when the referenced row no longer exists

      def initialize(@link, @tag, @label, @url, @stale = false)
      end

      # One-line list rendering: "[hist] GET https://…".
      def line : String
        "[#{tag}] #{label}"
      end
    end

    def self.resolve(store : Store, link : Store::EntityLink) : Resolved
      case link.ref_kind
      when .flow?     then resolve_flow(store, link)
      when .repeater? then resolve_repeater(store, link)
      when .fuzz?     then resolve_fuzz(store, link)
      else                 resolve_miner(store, link)
      end
    end

    def self.resolve_all(store : Store, links : Array(Store::EntityLink)) : Array(Resolved)
      links.map { |l| resolve(store, l) }
    end

    # Drop links that duplicate the issue's primary flow_id (shown on the evidence row).
    def self.dedupe_issue_flow(links : Array(Store::EntityLink), flow_id : Int64?) : Array(Store::EntityLink)
      return links unless fid = flow_id
      links.reject { |l| l.ref_kind.flow? && l.ref_id == fid }
    end

    private def self.resolve_flow(store : Store, link : Store::EntityLink) : Resolved
      if row = store.flow_row(link.ref_id)
        loc = flow_location(row)
        Resolved.new(link, link.ref_kind.tag, "#{row.method} #{loc}", row.url)
      else
        Resolved.new(link, link.ref_kind.tag, "flow ##{link.ref_id} (gone)", "flow ##{link.ref_id}", stale: true)
      end
    end

    private def self.resolve_repeater(store : Store, link : Store::EntityLink) : Resolved
      if rec = store.get_repeater(link.ref_id)
        label = rec.name || first_line(String.new(rec.request).scrub) || "repeater ##{rec.id}"
        Resolved.new(link, link.ref_kind.tag, label, rec.target)
      else
        Resolved.new(link, link.ref_kind.tag, "repeater ##{link.ref_id} (gone)", "repeater ##{link.ref_id}", stale: true)
      end
    end

    private def self.resolve_fuzz(store : Store, link : Store::EntityLink) : Resolved
      if rec = store.get_fuzz_session(link.ref_id)
        label = rec.name || first_line(rec.template) || "fuzz ##{rec.id}"
        Resolved.new(link, link.ref_kind.tag, label, rec.target)
      else
        Resolved.new(link, link.ref_kind.tag, "fuzz ##{link.ref_id} (gone)", "fuzz ##{link.ref_id}", stale: true)
      end
    end

    private def self.resolve_miner(store : Store, link : Store::EntityLink) : Resolved
      if rec = store.get_miner_session(link.ref_id)
        label = rec.name || first_line(String.new(rec.request)) || "miner ##{rec.id}"
        Resolved.new(link, link.ref_kind.tag, label, rec.target)
      else
        Resolved.new(link, link.ref_kind.tag, "miner ##{link.ref_id} (gone)", "miner ##{link.ref_id}", stale: true)
      end
    end

    private def self.flow_location(f : Store::FlowRow) : String
      f.target.starts_with?("http") ? f.target : "#{f.host}#{f.target}"
    end

    private def self.first_line(s : String) : String?
      s.each_line do |raw|
        line = raw.rstrip('\r').strip
        return line unless line.empty?
      end
      nil
    end
  end
end
