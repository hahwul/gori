# `gori run links` — the evidence pointers an Issue or Note carries to a captured Flow,
# a Repeater tab, or a Fuzz/Miner run. The markdown issue export already RESOLVED these
# (issues_export.cr); this is the surface that lists and edits them.
module Gori
  module CLI
    module Run
      EVIDENCE_LINK_HELP = "See also — attach flow/repeater/fuzz/miner evidence to an issue:\n" \
                           "  gori run links add --owner=issue --id=ISSUE_ID --ref=repeater --ref-id=REPEATER_ID"

      # `links add` is a POINTER and stays one (#1038). The TUI's "Link…" decides for the
      # operator and freezes by default, because it has one in front of it and a hint line to
      # say so; the headless surfaces stay mechanism-named, because an agent or a script
      # composes verbs and a verb that silently did two things is a worse contract. So say
      # which verb does both rather than making the caller discover it.
      ADD_KEEPS_NO_BYTES = "\nA pointer only. For a flow or repeater whose bytes must survive, use\n" \
                           "`gori run evidence freeze` (it links too, unless --no-link)."

      @[Subcommand("links", help: [
        {"links", "List/add/delete an issue's or note's evidence links"},
      ])]
      private def self.cmd_links(args : Array(String)) : Nil
        case sub = args.first?
        when "add"          then cmd_links_mutate(args[1..], add: true)
        when "delete", "rm" then cmd_links_mutate(args[1..], add: false)
        when "list"         then cmd_links_list(args[1..])
        else
          # Why this guard exists at all: see `verb_token?`. Local to links — `remove` is the
          # exact word `gori run -h` used to advertise, and it silently listed instead of
          # unlinking; with a mutate-only flag present it did fail, but blamed the flag
          # (`unknown option: --ref`) and never said `remove` is not a verb.
          if verb_token?(sub)
            abort "gori run links: unknown subcommand '#{sub}' (add, delete/rm, list)"
          end
          cmd_links_list(args)
        end
      end

      private def self.cmd_links_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        owner_s = "issue"
        owner_id : Int64? = nil
        format = :text
        leftover = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run links [list] --owner=issue|note --id=N\n\n" \
                     "List the evidence an issue or note points at. A pointer whose target was\n" \
                     "pruned is shown as (stale) rather than hidden, so \"no evidence\" and\n" \
                     "\"evidence that is gone\" stay distinguishable.\n\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run links add    --owner=issue|note --id=N --ref=KIND --ref-id=M\n" \
                     "  gori run links delete --owner=issue|note --id=N --ref=KIND --ref-id=M\n" \
                     "  (--ref is flow|repeater|fuzz|miner; `rm` is accepted for delete)"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--owner=KIND", "Owner kind: issue (default) | note") { |v| owner_s = v.strip.downcase }
          p.on("--id=N", "Owner issue/note id (required)") { |v| owner_id = parse_link_id(v, "--id") }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| leftover = before + after }
          p.invalid_option { |f| abort "gori run links: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run links: missing value for #{f}" }
        end
        parser.parse(args)
        # Only ever masked here by a flag mismatch: the COMPLETE mutate form aborts on `--ref`,
        # which the list parser does not own, but `links --project=X --owner=issue --id=1 delete`
        # listed and exited 0 with the verb discarded.
        refuse_list_leftovers(leftover, "links", "add, delete/rm, list")

        owner_kind = Store::LinkOwnerKind.parse(owner_s) ||
                     abort("gori run links: invalid --owner '#{owner_s}' (issue|note)")
        # Copy out of the closure first: `owner_id` is assigned inside an OptionParser block,
        # so Crystal keeps it nilable and `x || abort` does not narrow it in place.
        oid_opt = owner_id
        abort "gori run links: --id is required" if oid_opt.nil?
        oid = oid_opt

        store = open_store(resolve_read_project(project_name, db_path), read_only: true)
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
          puts(JSON.build { |j| j.array { resolved.each { |r| j.object { link_row_fields(j, r) } } } })
          return
        end
        if resolved.empty?
          STDERR.puts "no links on #{owner_kind.label} ##{oid}"
          return
        end
        resolved.each do |r|
          # `Resolved#line` is "[tag] label", and the label is `"#{row.method} #{loc}"` off the
          # wire — so an OSC 52 / set-window-title sequence in a captured request line drove the
          # operator's terminal on every `gori run links`. Every other CLI printer of captured
          # text goes through `term_safe`; this one did not.
          puts "#{CLI::Output.term_safe(r.line)}#{r.stale? ? "  (stale)" : ""}"
        end
      end

      # One link's fields: a row of `links list --format json`, and the body of `links add
      # --format json` (#1117), which adds `created` beside them. One method so the two
      # cannot drift.
      private def self.link_row_fields(j : JSON::Builder, r : Links::Resolved) : Nil
        j.field "id", r.link.id
        j.field "ref_kind", r.link.ref_kind.label
        j.field "ref_id", r.link.ref_id
        # Captured bytes (see Links.resolve_flow) — `one_line` so a raw 0x80 in an
        # h2 `:path` can't make this document invalid UTF-8, the same guard
        # `Issues::Export.append_links_json` and MCP `list_links` carry.
        j.field "label", Issues::Export.one_line(r.label)
        j.field "url", Issues::Export.one_line(r.url)
        j.field "stale", r.stale?
      end

      private def self.cmd_links_mutate(args : Array(String), *, add : Bool) : Nil
        # One branch for all three words this flag changes, rather than a ternary per use:
        # the parser body is already at the cyclomatic ceiling the lint gate holds.
        verb, action, tail = add ? {"add", "Attach", ADD_KEEPS_NO_BYTES} : {"delete", "Detach", ""}
        db_path : String? = nil
        project_name : String? = nil
        owner_s = "issue"
        owner_id : Int64? = nil
        ref_s : String? = nil
        ref_id : Int64? = nil
        format = :text
        leftover = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run links #{verb} --owner=issue|note --id=N --ref=KIND --ref-id=M\n\n" \
                     "#{action} an evidence pointer. --ref is flow|repeater|fuzz|miner.#{tail}"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--owner=KIND", "Owner kind: issue (default) | note") { |v| owner_s = v.strip.downcase }
          p.on("--id=N", "Owner issue/note id (required)") { |v| owner_id = parse_link_id(v, "--id") }
          p.on("--ref=KIND", "Target kind: flow|repeater|fuzz|miner (required)") { |v| ref_s = v.strip.downcase }
          p.on("--ref-id=M", "Target id (required)") { |v| ref_id = parse_link_id(v, "--ref-id") }
          # `add` only (#1117): it creates the row whose id a script needs back. `delete` has no
          # row left to describe, and a flag it parsed and ignored would be a silent drop.
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) } if add
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| leftover = before + after }
          p.invalid_option { |f| abort "gori run links #{verb}: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run links #{verb}: missing value for #{f}" }
        end
        parser.parse(args)
        # Every end of a link is named by a FLAG, so a positional here is always a mistake — most
        # likely a `--ref`/`--id` value the operator meant to attach to its flag. Silently dropping
        # it would file (or fail to remove) a different link than the one written.
        #
        # Refused AFTER `parse`, never inside the `unknown_args` block: Crystal's OptionParser runs
        # that callback BEFORE its `starts_with?('-')` → `invalid_option` sweep, and an unrecognized
        # flag is still sitting in the leftovers at that point. Aborting from inside therefore
        # pre-empted `invalid_option` and misdiagnosed a typo — `--refid=3` came back as "unexpected
        # argument" instead of "unknown option: --refid" plus the help listing the real flag names,
        # which is the one thing that tells the operator they dropped a dash. Deferring lets the
        # sweep win for flags and leaves this to catch genuine positionals (which is also why the
        # twelve `refuse_list_leftovers` sites were never exposed to it — they all defer too).
        unless leftover.empty?
          abort "gori run links #{verb}: unexpected argument#{leftover.size == 1 ? "" : "s"} " \
                "#{leftover.join(" ").inspect} — every end is named by a flag " \
                "(--owner, --id, --ref, --ref-id)"
        end

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
            puts link_add(store, owner_kind, oid, ref_kind, rid, format)
          else
            unless store.link_id(owner_kind, oid, ref_kind, rid)
              abort "gori run links delete: no link from #{owner_kind.label} ##{oid} to #{ref_kind.label} ##{rid}"
            end
            abort "gori run links rm: NOT removed (project busy) — the link is unchanged" unless store.remove_link(owner_kind, oid, ref_kind, rid)
            puts "Unlinked #{owner_kind.label} ##{oid} → #{ref_kind.label} ##{rid}."
          end
        ensure
          store.close
        end
      end

      # `links add`'s write and the line it answers with. Split out of `cmd_links_mutate`, which
      # is at the complexity bar the lint gate holds.
      #
      # Store#add_link returns nil when the pair already exists — that is the desired end
      # state, so the sentence says so rather than reporting a link that was not created. But a
      # write that did not COMMIT (a busy or read-only project) answers nil too, and the text
      # used to call that "already linked" — a link that did not exist. So the row is looked up
      # rather than trusted from the nil, and no row at all refuses, in both formats.
      # `--format json` (#1117) is the link's `links list --format json` row plus `created`,
      # false for a pair that was already linked, with THAT link's id: the row the next listing
      # shows.
      private def self.link_add(store : Store, owner_kind : Store::LinkOwnerKind, oid : Int64,
                                ref_kind : Store::LinkRefKind, rid : Int64, format : Symbol) : String
        created = store.add_link(owner_kind, oid, ref_kind, rid)
        # A new row in text mode needs no read-back — the write just named it. Every other case
        # does: nil is ambiguous, and JSON prints the row itself.
        return link_add_sentence(created, true, owner_kind, oid, ref_kind, rid).to_s if created && format != :json
        link = store.list_links(owner_kind, oid).find { |l| l.ref_kind == ref_kind && l.ref_id == rid }
        if format != :json && (sentence = link_add_sentence(created, !link.nil?, owner_kind, oid, ref_kind, rid))
          return sentence
        end
        unless link
          abort_closing(store, "gori run links add: no link from #{owner_kind.label} ##{oid} to #{ref_kind.label} ##{rid} " \
                               "after the write (project busy or unwritable, or removed by a peer) — try again")
        end
        resolved = Links.resolve(store, link)
        JSON.build do |j|
          j.object do
            link_row_fields(j, resolved)
            j.field "created", !created.nil?
          end
        end
      end

      # `links add`'s text answer, or nil when there is nothing true to say: no row was written
      # and none exists (`created` nil is "already there" AND "did not commit" — only `linked`,
      # the row read back, tells them apart). Public and pure so a spec can drive it; the
      # command refuses on nil.
      def self.link_add_sentence(created : Int64?, linked : Bool, owner_kind : Store::LinkOwnerKind, oid : Int64,
                                 ref_kind : Store::LinkRefKind, rid : Int64) : String?
        return "Linked #{owner_kind.label} ##{oid} → #{ref_kind.label} ##{rid}." if created
        return "#{owner_kind.label.capitalize} ##{oid} was already linked to #{ref_kind.label} ##{rid}." if linked
        nil
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
