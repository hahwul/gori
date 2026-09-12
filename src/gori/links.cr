require "./store"
require "./url"

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

    # Drop the link row that IS the issue's primary flow. One caller left: the "Manage links"
    # card, which is a list of REMOVABLE pointers, and the primary flow is not one — it is
    # `issues.flow_id`, a column, and deleting its link row would leave the column behind for
    # `issue_links` below to synthesise the row straight back. Everywhere the question is "what
    # backs this issue" — the RELATED card, the Markdown report, the JSON/MCP `links` array —
    # uses `issue_links` instead and shows the primary FIRST rather than not at all.
    def self.dedupe_issue_flow(links : Array(Store::EntityLink), flow_id : Int64?) : Array(Store::EntityLink)
      return links unless fid = flow_id
      links.reject { |l| l.ref_kind.flow? && l.ref_id == fid }
    end

    # An issue's related material in CARD order: the PRIMARY flow first, exactly once, then
    # every other link in link order.
    #
    # The primary flow used to be a SEPARATE thing — a `flow` meta row above the RELATED card,
    # a `- **Flow:**` bullet above the report's Related list — and this method's ancestor
    # (`dedupe_issue_flow`) existed to take it back OUT of the list so it would not appear
    # twice. An issue relates to traffic four ways (flow_id, entity links, frozen evidence,
    # retest steps) and the operator sees ONE question, "what backs this issue", so the answer
    # is one list and the seed flow is simply its first row.
    #
    # SYNTHESISED when `issues.flow_id` has no `entity_links` row of its own. `insert_issue`
    # writes that row in the same transaction as the issue and has since the table existed, so
    # the shapes that reach here are an issue filed BEFORE the entity_links migration, an
    # imported or hand-edited project, and a link deleted by SQL. Dropping the primary there
    # would make an issue's own seed vanish from the card and the report, so it is rebuilt from
    # the column instead. The synthetic row carries `id = 0`: it is not an `entity_links` row,
    # so nothing may remove it by id (the RELATED card's verbs read `ref_kind`/`ref_id` only;
    # unlinking lives in the LINKS overlay, which lists the table and skips the primary).
    #
    # A PRUNED flow is not one of these shapes: `delete_flows` nulls `issues.flow_id` along
    # with the link (`detach_flow_refs`), so an issue whose evidence was pruned has no primary
    # at all rather than a dangling one.
    def self.issue_links(links : Array(Store::EntityLink), issue_id : Int64,
                         flow_id : Int64?) : Array(Store::EntityLink)
      return links unless fid = flow_id
      primary = links.find { |l| l.ref_kind.flow? && l.ref_id == fid } || synthetic_flow_link(issue_id, fid)
      rest = links.reject { |l| l.ref_kind.flow? && l.ref_id == fid }
      rest.unshift(primary)
    end

    # The stand-in row for a `flow_id` the links table has no row for — see `issue_links`.
    def self.synthetic_flow_link(issue_id : Int64, flow_id : Int64) : Store::EntityLink
      Store::EntityLink.new(0_i64, Store::LinkOwnerKind::Issue, issue_id,
        Store::LinkRefKind::Flow, flow_id, 0_i64)
    end

    # `issue_links` over an issue record — the spelling every caller that has one uses.
    def self.issue_links(links : Array(Store::EntityLink), issue : Store::Issue) : Array(Store::EntityLink)
      issue_links(links, issue.id, issue.flow_id)
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
        # `.scrub` for parity with `resolve_repeater` above: this label is DISPLAY text built
        # from captured wire bytes, and the TUI funnels display text through
        # `Hotkeys.retag`, whose regex raises on a non-UTF-8 subject.
        label = rec.name || first_line(String.new(rec.request).scrub) || "miner ##{rec.id}"
        Resolved.new(link, link.ref_kind.tag, label, rec.target)
      else
        Resolved.new(link, link.ref_kind.tag, "miner ##{link.ref_id} (gone)", "miner ##{link.ref_id}", stale: true)
      end
    end

    # `Gori::Url.location`, not the `target.starts_with?("http")` this used to spell out: that
    # predicate is not the absolute-form test (RFC 3986 §3.1 makes a scheme case-insensitive),
    # so a captured `GET HTTP://host/x` was glued into `hostHTTP://host/x` — the exact doubling
    # `Store::FlowRow.absolute_form?`'s comment says the check exists to prevent.
    private def self.flow_location(f : Store::FlowRow) : String
      Gori::Url.location(f.host, f.target)
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
