require "json"
require "../../store"
require "../../links"
require "../../notes"

module Gori
  module MCP
    class Tools
      # Entity links — the evidence pointers an Issue or Note carries to a Flow / Repeater tab /
      # Fuzz run / Miner run. MCP already WROTE these (send_request, create/update_issue,
      # create_repeater) but had no way to read or remove one, so an agent could attach evidence
      # it could never review or correct. These are the read/unlink halves.

      private def list_links(h) : Result
        owner = link_owner(h)
        return owner if owner.is_a?(Result)
        owner_kind, owner_id = owner

        links = store.list_links(owner_kind, owner_id)
        Result.new(JSON.build do |j|
          j.object do
            j.field "owner_kind", owner_kind.label
            j.field "owner_id", owner_id
            j.field("links") do
              j.array do
                Links.resolve_all(store, links).each do |r|
                  j.object do
                    j.field "id", r.link.id
                    j.field "ref_kind", r.link.ref_kind.label
                    j.field "ref_id", r.link.ref_id
                    j.field "label", r.label
                    j.field "url", r.url
                    # A link whose target was pruned/deleted. Kept (not hidden) so the caller
                    # can tell "no evidence" from "evidence that no longer exists".
                    j.field "stale", true if r.stale?
                  end
                end
              end
            end
            j.field "total", links.size
          end
        end)
      end

      # add_link — attach an evidence pointer. Idempotent: Store#add_link returns nil when the
      # exact (owner, ref) pair already exists, which is a success, not a failure.
      private def add_entity_link(h) : Result
        owner = link_owner(h)
        return owner if owner.is_a?(Result)
        owner_kind, owner_id = owner
        ref = link_ref(h)
        return ref if ref.is_a?(Result)
        ref_kind, ref_id = ref

        created = store.add_link(owner_kind, owner_id, ref_kind, ref_id)
        Result.new({"owner_kind" => owner_kind.label, "owner_id" => owner_id,
                    "ref_kind" => ref_kind.label, "ref_id" => ref_id,
                    "id" => created || store.link_id(owner_kind, owner_id, ref_kind, ref_id),
                    "already_linked" => created.nil?}.to_json)
      end

      # remove_link — detach by the (owner, ref) pair, so a caller that knows what it linked
      # need not first look up the link row's own id.
      private def remove_entity_link(h) : Result
        owner = link_owner(h)
        return owner if owner.is_a?(Result)
        owner_kind, owner_id = owner
        ref = link_ref(h)
        return ref if ref.is_a?(Result)
        ref_kind, ref_id = ref

        unless store.link_id(owner_kind, owner_id, ref_kind, ref_id)
          return not_found("no link from #{owner_kind.label} #{owner_id} to #{ref_kind.label} #{ref_id}")
        end
        return busy("link NOT removed (store busy or unwritable); it is unchanged") unless store.remove_link(owner_kind, owner_id, ref_kind, ref_id)
        Result.new({"removed" => true, "owner_kind" => owner_kind.label, "owner_id" => owner_id,
                    "ref_kind" => ref_kind.label, "ref_id" => ref_id}.to_json)
      end

      # {kind, id} of the link owner, validating that the row actually exists — attaching
      # evidence to a nonexistent issue would otherwise "succeed" invisibly.
      private def link_owner(h) : {Store::LinkOwnerKind, Int64} | Result
        kind_s = str(h, "owner_kind").try(&.strip.downcase).presence
        return err("missing required 'owner_kind' (issue|note)", "INVALID_ARGUMENT", field: "owner_kind") unless kind_s
        kind = Store::LinkOwnerKind.parse(kind_s)
        return err("invalid owner_kind '#{kind_s}' (issue|note)", "INVALID_ARGUMENT", field: "owner_kind") unless kind
        id = int(h, "owner_id")
        return Result.new(id_error(h, "owner_id"), is_error: true) unless id

        exists = kind.issue? ? !store.get_issue(id).nil? : Notes.load(store).notes.any? { |n| n.id == id }
        return not_found("no #{kind.label} with id #{id}") unless exists
        {kind, id}
      end

      # {kind, id} of the link target. Validated the same way, for the same reason.
      private def link_ref(h) : {Store::LinkRefKind, Int64} | Result
        kind_s = str(h, "ref_kind").try(&.strip.downcase).presence
        return err("missing required 'ref_kind' (flow|repeater|fuzz|miner)", "INVALID_ARGUMENT", field: "ref_kind") unless kind_s
        kind = Store::LinkRefKind.parse(kind_s)
        return err("invalid ref_kind '#{kind_s}' (flow|repeater|fuzz|miner)", "INVALID_ARGUMENT", field: "ref_kind") unless kind
        id = int(h, "ref_id")
        return Result.new(id_error(h, "ref_id"), is_error: true) unless id
        return not_found("no #{kind.label} with id #{id}") unless link_ref_exists?(kind, id)
        {kind, id}
      end

      private def link_ref_exists?(kind : Store::LinkRefKind, id : Int64) : Bool
        case kind
        # flow_row / get_*_session are the row-only reads; get_flow would materialize the
        # request AND response BLOBs just to answer "does this exist?".
        when .flow?     then !store.flow_row(id).nil?
        when .repeater? then !store.get_repeater(id).nil?
        when .fuzz?     then !store.get_fuzz_session(id).nil?
        else                 !store.get_miner_session(id).nil?
        end
      end
    end
  end
end
