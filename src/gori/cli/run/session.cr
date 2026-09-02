# `gori run session` — the project's SESSION SLOTS: named identities, each one a header
# overlay plus the extract rules whose observed values belong to it (`Gori::SessionSlot`,
# DESIGN.md §7 2026-08-17).
#
# One list, two readers. The Authorize tab replays a captured request under EVERY slot and
# judges the answers against the baseline; a send seam (Repeater, Fuzz, the intercept
# forward) applies the ONE that is active. So `gori run session` and the TUI's identities
# card edit the same rows in the same settings row, and MCP's `*_session_slot` tools are the
# third reader of it.
#
# The ACTIVE pointer is not here, and cannot be: it is per-process and memory-only (see
# `SessionSlots` for why — restoring "admin is active" into an empty admin binding table
# hands the next send an overlay whose `$SESSION` is literal). `gori run` is one-shot, so a
# headless send names its identity on the send itself: `--slot NAME`.
module Gori
  module CLI
    module Run
      private def self.cmd_session(args : Array(String)) : Nil
        case sub = args.first?
        when "add"          then cmd_session_add(args[1..])
        when "from-flow"    then cmd_session_from_flow(args[1..])
        when "edit"         then cmd_session_edit(args[1..])
        when "rm", "delete" then cmd_session_rm(args[1..])
        when "baseline"     then cmd_session_baseline(args[1..])
        when "show"         then cmd_session_show(args[1..])
        when "list"         then cmd_session_list(args[1..])
        when nil            then cmd_session_list(args)
        when "activate"     then refuse_session_activate(args[1]?)
        else
          if (s = sub) && s.starts_with?('-')
            cmd_session_list(args)
          else
            STDERR.puts "gori run session: unknown subcommand '#{sub}'"
            STDERR.puts "Usage: gori run session [list] | show <name> | add | from-flow <id> | edit <name> | rm|delete <name> | baseline <name>"
            exit 1
          end
        end
      end

      # Named on purpose rather than left to "unknown subcommand": `activate` is the verb every
      # other surface has (the TUI picker, MCP `set_active_session_slot`), and an operator who
      # reads the guide will type it here. There is nothing for it to do — the pointer dies with
      # the process — so this says which flag carries the same intent instead of writing a
      # setting that a later run would silently ignore.
      private def self.refuse_session_activate(name : String?) : NoReturn
        abort "gori run session: the active slot is per-process and is never persisted " \
              "(a restored pointer resolves an empty binding table — see `gori run session list`). " \
              "Name it on the SEND instead: `gori run fuzz … --slot #{name || "NAME"}` " \
              "(also on repeater/mine/sequence/discover)."
      end

      # `--set`, `--remove`, `--rule`, `--baseline` — the writable half of a slot, shared by
      # `add` and `edit` so the two cannot drift on what a flag means. `set`/`remove`/`rule`
      # are nil until the flag appears at least once, which is what lets `edit` tell "leave
      # this collection alone" apart from "empty it" (`--clear-*`).
      # A CLASS, not a struct: `session_edit_flags` takes it as a parameter and the
      # OptionParser blocks mutate it, and a struct would be copied into that method — every
      # `--set` landing on a copy the caller never sees.
      private class SlotEdit
        property name : String?
        property set : Array({String, String})?
        property remove : Array(String)?
        property rules : Array(String)?
        property baseline : Bool?

        def initialize
          @name = nil
          @set = nil
          @remove = nil
          @rules = nil
          @baseline = nil
        end

        def push_set(pair : {String, String}) : Nil
          (@set ||= [] of {String, String}) << pair
        end

        def push_remove(header : String) : Nil
          (@remove ||= [] of String) << header
        end

        def push_rule(rule : String) : Nil
          (@rules ||= [] of String) << rule
        end
      end

      # The flags `add` and `edit` share. Declared once so `gori run session add --help` and
      # `edit --help` describe the same dialect (they are the same dialect).
      private def self.session_edit_flags(p : OptionParser, e : SlotEdit, cmd : String) : Nil
        p.on("--name=NAME", "The slot's name (on `edit`, renames it)") { |v| e.name = v.strip }
        p.on("--set=LINE", "Header to UPSERT, as 'Name: value' (repeatable)") { |v| e.push_set(parse_session_header(v, cmd)) }
        p.on("--remove=NAME", "Header to STRIP before sending (repeatable)") { |v| e.push_remove(v.strip) }
        p.on("--rule=NAME", "Extract rule (binding NAME) whose values belong to THIS slot (repeatable)") { |v| e.push_rule(v.strip) }
        p.on("--baseline", "Make this the Authorize baseline every other slot is judged against") { e.baseline = true }
        p.on("--no-baseline", "Clear the baseline flag (the first slot then inherits it)") { e.baseline = false }
        p.on("--clear-set", "Drop every set-header (combine with --set to replace them)") { e.set = [] of {String, String} }
        p.on("--clear-remove", "Drop every remove-header") { e.remove = [] of String }
        p.on("--clear-rules", "Claim no extract rule (its bindings go back to the global table)") { e.rules = [] of String }
      end

      # One `--set 'Name: value'`. Parsed by `Discover::Headers.parse_lines`, which is the
      # SAME parser the TUI's identity form runs the editor buffer through — a value may not
      # carry CR/LF and a name must be an RFC 7230 token, so a slot cannot forge a header
      # boundary into every request it overlays. Refused loudly rather than dropped: a
      # silently-skipped `--set Cookie: …` is an unauthenticated run that reports "found
      # nothing".
      private def self.parse_session_header(raw : String, cmd : String) : {String, String}
        rejected = [] of String
        pairs = Gori::Discover::Headers.parse_lines([raw], rejected)
        if pair = pairs.first?
          return pair
        end
        abort "#{cmd}: --set #{raw.inspect} is not a header — write it as 'Name: value', with a " \
              "name that is an RFC 7230 token and a value carrying no CR or LF"
      end

      # The project's slot registry. Every subcommand here goes through it rather than
      # writing `Store::SESSION_SLOTS_KEY` by hand, so the single-baseline rule and the
      # serialization live in one place (`SessionSlots`) for all three surfaces.
      private def self.session_slots(project_name : String?, db_path : String?, *,
                                     read_only : Bool = false) : {Store, Gori::SessionSlots}
        store = open_store(resolve_read_project(project_name, db_path), read_only: read_only)
        {store, Gori::SessionSlots.load(store)}
      end

      private def self.cmd_session_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        show_values = false
        leftover = [] of String
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run session [list] [options]\n\n" \
                     "The project's session slots: named identities, each a header overlay plus the\n" \
                     "extract rules whose bound values belong to it. The Authorize tab replays under\n" \
                     "every one of them; a send (Repeater/Fuzz/intercept forward) applies the ONE\n" \
                     "named by --slot.\n\n" \
                     "Header VALUES are [REDACTED] — a session cookie is a credential and this list\n" \
                     "is scrollback. --show-values prints them."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--show-values", "Print set-header values instead of [REDACTED]") { show_values = true }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| leftover = before + after }
          p.invalid_option { |f| abort "gori run session: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run session: missing value for #{f}" }
        end
        parser.parse(args)
        refuse_list_leftovers(leftover, "session", "add, from-flow, edit, rm/delete, baseline, show, list")

        store, slots = session_slots(project_name, db_path, read_only: true)
        begin
          list = slots.slots
          if format == :json
            puts(JSON.build { |j| j.array { list.each { |s| session_slot_json(j, s, show_values) } } })
          elsif list.empty?
            puts "No session slots saved. Add one with `gori run session add --name admin " \
                 "--set 'Cookie: session=…'`, or open the TUI's Authorize tab (it starts from a " \
                 "built-in as-captured/anonymous pair until you save over it)."
          else
            list.each { |s| puts session_slot_row(s, show_values) }
            puts
            puts "No slot is active in a `gori run` process — the pointer is per-process and is " \
                 "never persisted. Name one on the send: --slot NAME."
          end
        ensure
          store.close
        end
      end

      private def self.cmd_session_show(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        show_values = false
        positional = [] of String
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run session show <name> [options]\n\n" \
                     "One slot in full: the headers it upserts, the ones it strips, and the extract\n" \
                     "rules whose bound values land in its table instead of the global one."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--show-values", "Print set-header values instead of [REDACTED]") { show_values = true }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run session show: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run session show: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run session show: too many arguments (expected one name, got: #{positional.join(" ")})" if positional.size > 1
        name = positional.first?
        abort "gori run session show: name a slot (`gori run session list` shows them)" if name.nil?

        store, slots = session_slots(project_name, db_path)
        begin
          slot = slots.find(name)
          abort "gori run session show: no session slot named #{name.inspect}" unless slot
          if format == :json
            puts(JSON.build { |j| session_slot_json(j, slot, show_values) })
          else
            puts session_slot_detail(slot, show_values)
          end
        ensure
          store.close
        end
      end

      private def self.cmd_session_add(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        edit = SlotEdit.new
        positional = [] of String
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run session add --name NAME [options]\n\n" \
                     "Add a session slot. A slot that sets or strips nothing is `as captured` — the\n" \
                     "no-overlay baseline, worth having by name so a run can say which request went\n" \
                     "out under its own session.\n\n" \
                     "  gori run session add --name admin --set 'Cookie: session=abc' --rule SESSION\n" \
                     "  gori run session add --name anonymous --remove Cookie --remove Authorization"
          session_edit_flags(p, edit, "gori run session add")
          # Named here rather than left to `invalid_option`: the feature is real and an
          # operator reading about it will reach for it as a flag on `add`. It is its own
          # subcommand because it takes no `--set`/`--clear-*` — it BUILDS the overlay.
          p.on("--from-flow=ID", "(moved) build the overlay from a captured login flow") do |v|
            abort "gori run session add: --from-flow is its own subcommand — " \
                  "`gori run session from-flow #{v} --name NAME`"
          end
          p.on("--project=NAME", "Project to write (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to write") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = one_positional_list(before, after, "gori run session add", "<name>") }
          p.invalid_option { |f| abort "gori run session add: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run session add: missing value for #{f}" }
        end
        parser.parse(args)
        # `session add admin` reads as naturally as `--name admin`; accept both, and refuse
        # the pair rather than picking a winner.
        name = edit.name || positional.first?
        abort "gori run session add: name the slot (--name NAME)" if name.nil? || name.empty?

        store, slots = session_slots(project_name, db_path)
        begin
          # Case-INSENSITIVELY (`SessionSlots#name_clash`): `admin` and `Admin` are one identity
          # to Authorize, and creating both left every run in the project refusing to start.
          if taken = slots.name_clash(name)
            abort "gori run session add: a slot called #{taken.inspect} already exists " \
                  "(change it with `gori run session edit #{taken}`). Names are compared " \
                  "case-insensitively — Authorize reads #{name.inspect} and #{taken.inspect} " \
                  "as one identity and refuses a set holding both"
          end
          slot = Gori::SessionSlot.new(name,
            edit.set || [] of {String, String}, edit.remove || [] of String,
            edit.baseline == true, edit.rules || [] of String)
          abort "gori run session add: the project could not be written — #{name.inspect} was NOT saved" unless slots.add(slot)
          puts session_slot_row(slot, false)
        ensure
          store.close
        end
      end

      # `gori run session from-flow <id> --name NAME` — one captured login exchange turned into
      # a saved slot, so that carrying a session stops being a three-step playbook (an extract
      # rule + a Match & Replace + `--bind-from` on every sweep).
      #
      # The reading lives in `Gori::SessionFromFlow`, not here: MCP `create_session_slot{flow}`
      # is the same feature, and a second copy of "which header wins" is how two surfaces come
      # to build different identities from one flow.
      private def self.cmd_session_from_flow(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        slot_name : String? = nil
        baseline = false
        show_values = false
        positional = [] of String
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run session from-flow <flow-id> --name NAME [options]\n\n" \
                     "Build a session slot from a captured LOGIN exchange. gori reads the flow's\n" \
                     "response and copies what it finds into the slot's header overlay:\n\n" \
                     "  * every Set-Cookie name=value, folded into one Cookie: header (attributes\n" \
                     "    dropped; a cookie the response DELETES is skipped);\n" \
                     "  * the response's own Authorization, else a top-level access_token/token/\n" \
                     "    id_token string in a JSON body as 'Authorization: Bearer <value>', else\n" \
                     "    the request's own Authorization.\n\n" \
                     "The overlay is LITERAL — the bytes that login handed back, saved with the\n" \
                     "project and applied by `--slot NAME` on every later send. It does NOT\n" \
                     "re-authenticate. A token that ROTATES (a short-lived JWT, a per-request CSRF\n" \
                     "value) belongs on the extract-rule path instead: `gori run rewriter extract`\n" \
                     "plus `--bind-from FLOW`, which re-mints the value once per run.\n\n" \
                     "  gori run session from-flow 4211 --name admin\n" \
                     "  gori run repeater send --flow 900 --slot admin"
          p.on("--name=NAME", "Name for the new slot (required; must not already exist)") { |v| slot_name = v.strip }
          p.on("--baseline", "Make it the Authorize baseline every other slot is judged against") { baseline = true }
          p.on("--show-values", "Print the captured header values instead of [REDACTED]") { show_values = true }
          p.on("--project=NAME", "Project to read and write (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read and write") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run session from-flow: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run session from-flow: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run session from-flow: too many arguments (expected one flow id, got: " \
              "#{positional.join(" ")})" if positional.size > 1
        raw = positional.first?
        abort "gori run session from-flow: name the captured flow to read " \
              "(`gori run history` lists them)" if raw.nil?
        flow_id = raw.to_i64?
        abort "gori run session from-flow: #{raw.inspect} is not a flow id" if flow_id.nil?
        # Copied out of the closured local so the compiler can narrow it; `parser.parse` is
        # what filled it, and a var a block assigns to stays nilable at every later read.
        name = slot_name
        abort "gori run session from-flow: name the slot (--name NAME)" if name.nil? || name.empty?

        store, slots = session_slots(project_name, db_path)
        begin
          # Checked BEFORE the flow read so the cheap, deterministic refusal comes first — the
          # same order `session add` uses, and the one that keeps a duplicate name from being
          # reported as "that flow is not a login".
          if taken = slots.name_clash(name)
            abort "gori run session from-flow: a slot called #{taken.inspect} already exists " \
                  "(change it with `gori run session edit #{taken}`, or pick another --name). " \
                  "Names are compared case-insensitively"
          end
          detail = store.get_flow(flow_id)
          abort "gori run session from-flow: no flow ##{flow_id} in this project " \
                "(`gori run history` lists them)" unless detail
          drafted = Gori::SessionFromFlow.draft(detail)
          if refusal = drafted.as?(Gori::SessionFromFlow::Refusal)
            abort "gori run session from-flow: flow ##{flow_id} — #{refusal.message}"
          end
          draft = drafted.as(Gori::SessionFromFlow::Draft)
          slot = draft.slot(name, baseline)
          abort "gori run session from-flow: the project could not be written — " \
                "#{name.inspect} was NOT saved" unless slots.add(slot)
          puts session_slot_row(slot, show_values)
          # Provenance on stderr, so stdout stays the one row `session add` prints and a script
          # that pipes it keeps working. Names WHERE each header came from and never a value.
          draft.sources.each { |line| STDERR.puts "from-flow: #{line}" }
          STDERR.puts "from-flow: a literal overlay — it does not re-authenticate. Send as it " \
                      "with `--slot #{name}`; a rotating token wants `rewriter extract` + `--bind-from`."
        ensure
          store.close
        end
      end

      private def self.cmd_session_edit(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        edit = SlotEdit.new
        positional = [] of String
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run session edit <name> [options]\n\n" \
                     "Change a slot. A collection flag REPLACES that whole collection: passing --set\n" \
                     "once rewrites the set-headers, and --clear-set empties them. A flag you do not\n" \
                     "pass leaves its collection exactly as it was.\n\n" \
                     "  gori run session edit admin --clear-set --set 'Cookie: session=new'\n" \
                     "  gori run session edit admin --name superuser"
          session_edit_flags(p, edit, "gori run session edit")
          p.on("--project=NAME", "Project to write (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to write") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = one_positional_list(before, after, "gori run session edit", "<name>") }
          p.invalid_option { |f| abort "gori run session edit: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run session edit: missing value for #{f}" }
        end
        parser.parse(args)
        target = positional.first?
        abort "gori run session edit: name the slot to change (`gori run session list`)" if target.nil?

        store, slots = session_slots(project_name, db_path)
        begin
          current = slots.find(target)
          abort "gori run session edit: no session slot named #{target.inspect}" unless current
          renamed = edit.name || current.name
          # `except:` is the row being renamed, so `edit admin --name ADMIN` re-cases a slot's
          # own name without reading as a collision with itself.
          if taken = slots.name_clash(renamed, except: current.name)
            abort "gori run session edit: another slot is already called #{taken.inspect} " \
                  "(names are compared case-insensitively)"
          end
          abort "gori run session edit: a slot needs a name" if renamed.empty?
          updated = Gori::SessionSlot.new(renamed,
            edit.set || current.set_headers, edit.remove || current.remove_headers,
            edit.baseline.nil? ? current.baseline? : edit.baseline == true,
            edit.rules || current.rules)
          abort "gori run session edit: the project could not be written — " \
                "#{target.inspect} is unchanged" unless slots.update(target, updated)
          puts session_slot_row(updated, false)
        ensure
          store.close
        end
      end

      private def self.cmd_session_rm(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        positional = [] of String
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run session rm <name> [options]\n\n" \
                     "Delete a session slot. Any extract rule it claimed goes back to writing the\n" \
                     "GLOBAL binding table, which is where an unclaimed rule has always written."
          p.on("--project=NAME", "Project to write (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to write") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run session rm: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run session rm: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run session rm: too many arguments (expected one name, got: #{positional.join(" ")})" if positional.size > 1
        name = positional.first?
        abort "gori run session rm: name the slot to delete (`gori run session list`)" if name.nil?

        store, slots = session_slots(project_name, db_path)
        begin
          abort "gori run session rm: no session slot named #{name.inspect}" unless slots.find(name)
          abort "gori run session rm: the project could not be written — " \
                "#{name.inspect} is still there" unless slots.remove(name)
          puts "deleted session slot #{name.inspect}"
        ensure
          store.close
        end
      end

      private def self.cmd_session_baseline(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        positional = [] of String
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run session baseline <name> [options]\n\n" \
                     "Move the Authorize BASELINE — the one slot every other slot's response is\n" \
                     "judged against. Exactly one slot holds it."
          p.on("--project=NAME", "Project to write (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to write") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run session baseline: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run session baseline: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run session baseline: too many arguments (expected one name, got: #{positional.join(" ")})" if positional.size > 1
        name = positional.first?
        abort "gori run session baseline: name the slot (`gori run session list`)" if name.nil?

        store, slots = session_slots(project_name, db_path)
        begin
          abort "gori run session baseline: no session slot named #{name.inspect}" unless slots.find(name)
          abort "gori run session baseline: the project could not be written — the baseline " \
                "did not move" unless slots.set_baseline(name)
          puts "#{name} is the baseline"
        ensure
          store.close
        end
      end

      # `◆ admin      sets Cookie · rules $SESSION` — the baseline diamond and the same
      # header-NAMES-only summary the TUI's identities card renders, for the same reason.
      def self.session_slot_row(slot : Gori::SessionSlot, show_values : Bool) : String
        mark = slot.baseline? ? "◆" : " "
        body = show_values ? session_slot_verbose(slot) : slot.summary
        rules = slot.rules.empty? ? "" : " · rules #{Env.token_list(slot.rules)}"
        "#{mark} #{slot.name.ljust(18)} #{body}#{rules}"
      end

      # The same one-liner with the VALUES in it (`--show-values`), so the row a script greps
      # and the row an operator inspects stay one shape.
      private def self.session_slot_verbose(slot : Gori::SessionSlot) : String
        return "as captured" if slot.passthrough?
        parts = [] of String
        unless slot.set_headers.empty?
          parts << "sets #{slot.set_headers.map { |(n, v)| "#{n}: #{v}" }.join(", ")}"
        end
        parts << "drops #{slot.remove_headers.join(", ")}" unless slot.remove_headers.empty?
        parts.join(" · ")
      end

      def self.session_slot_detail(slot : Gori::SessionSlot, show_values : Bool) : String
        String.build do |io|
          io << slot.name
          io << "  (baseline)" if slot.baseline?
          io << "  (as captured — no overlay)" if slot.passthrough?
          io << '\n'
          slot.set_headers.each do |(n, v)|
            io << "  set     " << n << ": " << (show_values ? v : "[REDACTED]") << '\n'
          end
          slot.remove_headers.each { |n| io << "  remove  " << n << '\n' }
          slot.rules.each { |n| io << "  rule    " << Settings.env_prefix << n << '\n' }
        end
      end

      def self.session_slot_json(j : JSON::Builder, slot : Gori::SessionSlot, show_values : Bool) : Nil
        j.object do
          j.field "name", slot.name
          j.field "baseline", slot.baseline?
          j.field "passthrough", slot.passthrough?
          j.field "set" do
            j.array do
              slot.set_headers.each do |(n, v)|
                j.object do
                  j.field "name", n
                  j.field "value", show_values ? v : "[REDACTED]"
                end
              end
            end
          end
          j.field("remove") { j.array { slot.remove_headers.each { |n| j.string n } } }
          j.field("rules") { j.array { slot.rules.each { |n| j.string n } } }
        end
      end
    end
  end
end
