require "json"
require "../../store"
require "../../links"
require "../../issues_export" # Issues::Export.one_line
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
                    # `one_line`, like every other captured value MCP emits (see
                    # `Serialize.text`'s contract). Both are built from wire bytes —
                    # `Links.resolve_flow` composes them from the flow's method/host/target,
                    # which `Codec::Http1.parse_request_head` builds with a plain `String.new`
                    # — so an h2 `:path` carrying a raw 0x80 made this whole JSON-RPC response
                    # line invalid UTF-8. Same pair, same fix as `Issues::Export.append_links_json`.
                    j.field "label", Issues::Export.one_line(r.label)
                    j.field "url", Issues::Export.one_line(r.url)
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

      # The tools/list schemas for the flow-link tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_links_tools(j : JSON::Builder) : Nil
        tool j, "list_links",
          "List the evidence pointers an Issue or Note carries — to a captured Flow, a " \
          "Repeater tab, or a Fuzz/Miner run — each resolved to a human label and URL. " \
          "A pointer whose target was pruned comes back with stale:true rather than being " \
          "dropped, so you can tell \"no evidence\" from \"evidence that is gone\"." do |s|
          s.field "owner_kind", strprop("issue|note"), required: true
          s.field "owner_id", intprop("the issue or note id"), required: true
        end

        return unless @allow_actions

        tool j, "add_link",
          "Attach an evidence pointer from an Issue or Note to a Flow / Repeater tab / " \
          "Fuzz or Miner run. Idempotent — re-linking the same pair returns " \
          "already_linked:true rather than erroring or duplicating." do |s|
          s.field "owner_kind", strprop("issue|note"), required: true
          s.field "owner_id", intprop("the issue or note id"), required: true
          s.field "ref_kind", strprop("flow|repeater|fuzz|miner"), required: true
          s.field "ref_id", intprop("id of the linked flow/repeater/fuzz/miner"), required: true
        end

        tool j, "remove_link",
          "Detach an evidence pointer, addressed by the same (owner, ref) pair add_link " \
          "takes — no need to look up the link row's own id first." do |s|
          s.field "owner_kind", strprop("issue|note"), required: true
          s.field "owner_id", intprop("the issue or note id"), required: true
          s.field "ref_kind", strprop("flow|repeater|fuzz|miner"), required: true
          s.field "ref_id", intprop("id of the linked flow/repeater/fuzz/miner"), required: true
        end
      end
    end
  end
end
