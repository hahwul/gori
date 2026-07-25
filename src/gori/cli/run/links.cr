# `gori run links` — the evidence pointers an Issue or Note carries to a captured Flow,
# a Repeater tab, or a Fuzz/Miner run. The markdown issue export already RESOLVED these
# (issues_export.cr); this is the surface that lists and edits them.
module Gori
  module CLI
    module Run
      private def self.cmd_links(args : Array(String)) : Nil
        case args.first?
        when "add"          then cmd_links_mutate(args[1..], add: true)
        when "delete", "rm" then cmd_links_mutate(args[1..], add: false)
        when "list", nil    then cmd_links_list(args.empty? ? args : args[1..])
        else                     cmd_links_list(args)
        end
      end

      private def self.cmd_links_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        owner_s = "issue"
        owner_id : Int64? = nil
        format = :text

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run links [list] --owner=issue|note --id=N\n\n" \
                     "List the evidence an issue or note points at. A pointer whose target was\n" \
                     "pruned is shown as (stale) rather than hidden, so \"no evidence\" and\n" \
                     "\"evidence that is gone\" stay distinguishable."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--owner=KIND", "Owner kind: issue (default) | note") { |v| owner_s = v.strip.downcase }
          p.on("--id=N", "Owner issue/note id (required)") { |v| owner_id = parse_link_id(v, "--id") }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run links: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run links: missing value for #{f}" }
        end
        parser.parse(args)

        owner_kind = Store::LinkOwnerKind.parse(owner_s) ||
                     abort("gori run links: invalid --owner '#{owner_s}' (issue|note)")
        # Copy out of the closure first: `owner_id` is assigned inside an OptionParser block,
        # so Crystal keeps it nilable and `x || abort` does not narrow it in place.
        oid_opt = owner_id
        abort "gori run links: --id is required" if oid_opt.nil?
        oid = oid_opt

        store = open_store(resolve_read_project(project_name, db_path))
        resolved = begin
          # Validate the owner exists, like the mutate path and the MCP list_links tool do —
          # otherwise a typo'd id prints "no links on issue #99999", which reads as "this
          # issue has no evidence" rather than "there is no such issue".
          unless link_owner_exists?(store, owner_kind, oid)
            store.close
            abort "gori run links: no #{owner_kind.label} with id #{oid}"
          end
          Links.resolve_all(store, store.list_links(owner_kind, oid))
        ensure
          store.close
        end

        if format == :json
          puts(JSON.build do |j|
            j.array do
              resolved.each do |r|
                j.object do
                  j.field "id", r.link.id
                  j.field "ref_kind", r.link.ref_kind.label
                  j.field "ref_id", r.link.ref_id
                  j.field "label", r.label
                  j.field "url", r.url
                  j.field "stale", r.stale?
                end
              end
            end
          end)
          return
        end
        if resolved.empty?
          STDERR.puts "no links on #{owner_kind.label} ##{oid}"
          return
        end
        resolved.each do |r|
          puts "#{r.line}#{r.stale? ? "  (stale)" : ""}"
        end
      end

      private def self.cmd_links_mutate(args : Array(String), *, add : Bool) : Nil
        verb = add ? "add" : "delete"
        db_path : String? = nil
        project_name : String? = nil
        owner_s = "issue"
        owner_id : Int64? = nil
        ref_s : String? = nil
        ref_id : Int64? = nil

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run links #{verb} --owner=issue|note --id=N --ref=KIND --ref-id=M\n\n" \
                     "#{add ? "Attach" : "Detach"} an evidence pointer. --ref is flow|repeater|fuzz|miner."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--owner=KIND", "Owner kind: issue (default) | note") { |v| owner_s = v.strip.downcase }
          p.on("--id=N", "Owner issue/note id (required)") { |v| owner_id = parse_link_id(v, "--id") }
          p.on("--ref=KIND", "Target kind: flow|repeater|fuzz|miner (required)") { |v| ref_s = v.strip.downcase }
          p.on("--ref-id=M", "Target id (required)") { |v| ref_id = parse_link_id(v, "--ref-id") }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run links #{verb}: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run links #{verb}: missing value for #{f}" }
        end
        parser.parse(args)

        owner_kind = Store::LinkOwnerKind.parse(owner_s) ||
                     abort("gori run links #{verb}: invalid --owner '#{owner_s}' (issue|note)")
        oid, ref_kind, rid = resolve_link_ends(verb, owner_id, ref_s, ref_id)

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          # Both ends must exist, or `add` would file an orphan row pointing at nothing and
          # still report success (the MCP add_link tool validates the same way).
          unless link_owner_exists?(store, owner_kind, oid)
            abort "gori run links #{verb}: no #{owner_kind.label} with id #{oid}"
          end
          unless link_ref_exists?(store, ref_kind, rid)
            abort "gori run links #{verb}: no #{ref_kind.label} with id #{rid}"
          end

          if add
            # Store#add_link returns nil when the pair already exists — that is the desired
            # end state, so say so rather than reporting a link that was not created.
            if store.add_link(owner_kind, oid, ref_kind, rid)
              puts "Linked #{owner_kind.label} ##{oid} → #{ref_kind.label} ##{rid}."
            else
              puts "#{owner_kind.label.capitalize} ##{oid} was already linked to #{ref_kind.label} ##{rid}."
            end
          else
            unless store.link_id(owner_kind, oid, ref_kind, rid)
              abort "gori run links delete: no link from #{owner_kind.label} ##{oid} to #{ref_kind.label} ##{rid}"
            end
            store.remove_link(owner_kind, oid, ref_kind, rid)
            puts "Unlinked #{owner_kind.label} ##{oid} → #{ref_kind.label} ##{rid}."
          end
        ensure
          store.close
        end
      end

      # The required {owner id, ref kind, ref id} triple. Split out of cmd_links_mutate to keep
      # it under the cyclomatic-complexity bar. Takes the parsed values as ARGUMENTS rather than
      # reading them from the enclosing scope: they are assigned inside OptionParser blocks, so
      # in place Crystal keeps them nilable and `x || abort` does not narrow them.
      private def self.resolve_link_ends(verb : String, owner_id : Int64?, ref_s : String?,
                                         ref_id : Int64?) : {Int64, Store::LinkRefKind, Int64}
        abort "gori run links #{verb}: --id is required" if owner_id.nil?
        abort "gori run links #{verb}: --ref is required (flow|repeater|fuzz|miner)" if ref_s.nil?
        abort "gori run links #{verb}: --ref-id is required" if ref_id.nil?
        ref_kind = Store::LinkRefKind.parse(ref_s) ||
                   abort("gori run links #{verb}: invalid --ref '#{ref_s}' (flow|repeater|fuzz|miner)")
        {owner_id, ref_kind, ref_id}
      end

      private def self.parse_link_id(v : String, flag : String) : Int64
        v.to_i64? || abort("gori run links: invalid #{flag} #{v.inspect} (expected an integer)")
      end

      private def self.link_owner_exists?(store : Store, kind : Store::LinkOwnerKind, id : Int64) : Bool
        kind.issue? ? !store.get_issue(id).nil? : Notes.load(store).notes.any? { |n| n.id == id }
      end

      private def self.link_ref_exists?(store : Store, kind : Store::LinkRefKind, id : Int64) : Bool
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
