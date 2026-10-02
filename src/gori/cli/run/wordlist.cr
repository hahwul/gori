# `gori run wordlist` — the global wordlist catalog (#1353): named lists under
# `$GORI_HOME/wordlists`, selected BY NAME from `--wordlist`/`-w` on fuzz, mine, discover and
# cookie --crack, from any working directory.
#
# The catalog is `Gori::WordlistCatalog`; this file only parses argv and prints. Two rules hold
# across every verb: a listing and `show` never print a list's VALUES unless asked (`--head`) —
# an operator's list can be a credential list or values lifted from a capture — and no verb
# normalizes a list's bytes (a blank line and a `#` line are payloads to the Fuzzer).
module Gori
  module CLI
    module Run
      @[Subcommand("wordlist", help: [
        {"wordlist (list)", "List the global wordlist catalog — names and sizes, never values"},
        {"wordlist show <name>", "One list's metadata; --head N also prints its first lines"},
        {"wordlist save <name>", "Save a list from --from FILE|-, --value V, or stdin (no overwrite without --overwrite)"},
        {"wordlist rename", "wordlist rename <old> <new> — rename a list (no overwrite without --overwrite)"},
        {"wordlist delete <name>", "Delete a list from the catalog (needs --yes)"},
      ])]
      private def self.cmd_wordlist(args : Array(String)) : Nil
        case sub = args.first?
        when "list", "ls"   then cmd_wordlist_list(args[1..])
        when "show"         then cmd_wordlist_show(args[1..])
        when "save", "add"  then cmd_wordlist_save(args[1..])
        when "rename", "mv" then cmd_wordlist_rename(args[1..])
        when "delete", "rm" then cmd_wordlist_delete(args[1..])
        else
          # Verb-only subcommand: an unknown word must not fall through to the read (the
          # `notes remove` / `issues remove` class — a mutation that silently listed instead).
          if (s = sub) && verb_token?(s)
            abort "gori run wordlist: unknown subcommand '#{s}' (list, show, save, rename, delete)"
          end
          cmd_wordlist_list(args)
        end
      end

      # A catalog refusal in this surface's words: the builder's sentence, plus the flag that
      # answers the one refusal a flag can answer.
      private def self.wordlist_error(verb : String, ex : WordlistCatalog::Error) : NoReturn
        hint = ex.reason.exists? ? " (--overwrite replaces it)" : ""
        abort "gori run wordlist #{verb}: #{ex.message}#{hint}"
      end

      # `list` prints the catalog's directory entries: stat metadata only, never a value.
      private def self.cmd_wordlist_list(args : Array(String)) : Nil
        format = :text
        positional = parse_args(args, "gori run wordlist") do |p|
          p.banner = "Usage: gori run wordlist [list] [options]\n\n" \
                     "List the lists in #{Paths.wordlists_dir}. Each is a plain file: select one by\n" \
                     "name with `gori run fuzz -w NAME`, `gori run mine --wordlist NAME`, `gori run\n" \
                     "discover --wordlist NAME`. A bare name is looked up in the current directory\n" \
                     "first, then here; anything with a `/` is a path and is read as given."
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end
        if msg = no_positional_error(positional, "gori run wordlist", "to inspect one list, use `gori run wordlist show <name>`")
          abort msg
        end

        listing = WordlistCatalog.list
        if format == :json
          puts JSON.build { |j| j.array { listing.entries.each { |e| wordlist_entry_json(j, e) } } }
        elsif listing.entries.empty?
          STDERR.puts "no wordlists in #{Paths.wordlists_dir} — save one with " \
                      "`gori run wordlist save NAME --from FILE`"
        else
          puts wordlist_table(listing.entries)
        end
        if listing.truncated
          STDERR.puts "gori run wordlist: showing the first #{listing.entries.size} lists — the catalog holds more"
        end
      end

      # The pure renderers below are public so a spec can drive them: the verbs around them
      # `abort` and `puts`, which an in-process example cannot observe.
      def self.wordlist_table(entries : Array(WordlistCatalog::Entry)) : String
        width = entries.max_of(&.name.size).clamp(4, 60)
        String.build do |io|
          io << "NAME".ljust(width) << "  " << "SIZE".rjust(9) << "  MODIFIED\n"
          entries.each do |e|
            name = CLI::Output.term_safe(e.name)
            io << name.ljust(width) << "  " << CLI::Output.human_size(e.bytes).rjust(9) << "  "
            io << CLI::Output.iso_time_utc(e.modified.to_unix_ms * 1000)
            io << "  (symlink)" if e.symlink
            io << '\n'
          end
        end.chomp
      end

      def self.wordlist_entry_json(j : JSON::Builder, e : WordlistCatalog::Entry) : Nil
        j.object do
          j.field "name", e.name
          j.field "path", e.path
          j.field "bytes", e.bytes
          j.field "modified", CLI::Output.iso_time_utc(e.modified.to_unix_ms * 1000)
          j.field "symlink", e.symlink
        end
      end

      # `show`: metadata plus a BOUNDED line count; the first lines only with `--head`.
      private def self.cmd_wordlist_show(args : Array(String)) : Nil
        format = :text
        head = 0
        positional = parse_args(args, "gori run wordlist show") do |p|
          p.banner = "Usage: gori run wordlist show <name> [--head N] [options]\n\n" \
                     "Print one list's path, size and line count (counted over at most " \
                     "#{WordlistCatalog::LINE_SCAN_MAX // (1024 * 1024)} MiB).\n" \
                     "Its values are NOT printed unless you ask: --head N prints the first N lines\n" \
                     "(at most #{WordlistCatalog::PREVIEW_LINES_MAX}) — a list can hold credentials."
          p.on("--head=N", "Also print the first N lines (values — may be sensitive)") { |v| head = parse_nonneg(v, "--head") }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end
        name = positional.first? || abort "gori run wordlist show: expected a wordlist name"
        if msg = extra_positional_error(positional, "gori run wordlist show", "wordlist name")
          abort msg
        end

        info = begin
          WordlistCatalog.info(name)
        rescue ex : WordlistCatalog::Error
          wordlist_error("show", ex)
        end
        preview = if head > 0
                    begin
                      WordlistCatalog.preview(name, head)
                    rescue ex : WordlistCatalog::Error
                      wordlist_error("show", ex)
                    end
                  end
        if format == :json
          puts JSON.build { |j| wordlist_info_json(j, info, preview) }
        else
          puts wordlist_info_text(info, preview)
        end
      end

      def self.wordlist_info_json(j : JSON::Builder, info : WordlistCatalog::Info,
                                  preview : WordlistCatalog::Preview?) : Nil
        e = info.entry
        j.object do
          j.field "name", e.name
          j.field "path", e.path
          j.field "bytes", e.bytes
          j.field "modified", CLI::Output.iso_time_utc(e.modified.to_unix_ms * 1000)
          j.field "symlink", e.symlink
          j.field "lines", info.lines
          j.field "lines_complete", info.lines_complete
          if pv = preview
            # JSON must be valid UTF-8; a line that is not is scrubbed here and only here.
            j.field "preview", pv.lines.map(&.scrub)
            j.field "preview_truncated", pv.truncated
          end
        end
      end

      def self.wordlist_info_text(info : WordlistCatalog::Info, preview : WordlistCatalog::Preview?) : String
        e = info.entry
        String.build do |io|
          io << CLI::Output.term_safe(e.name) << '\n'
          io << "  path      " << e.path << '\n'
          io << "  size      " << CLI::Output.human_size(e.bytes) << " (" << e.bytes << " bytes)\n"
          lines = info.lines_complete ? info.lines.to_s : "more than #{info.lines} (counted the first " \
                                                          "#{WordlistCatalog::LINE_SCAN_MAX // (1024 * 1024)} MiB)"
          io << "  lines     " << lines << '\n'
          io << "  modified  " << CLI::Output.iso_time_utc(e.modified.to_unix_ms * 1000) << '\n'
          io << "  symlink   yes\n" if e.symlink
          if pv = preview
            io << '\n'
            shown = pv.lines
            shown.each { |l| io << CLI::Output.term_safe(l) << '\n' }
            io << "…\n" if pv.truncated
          end
        end.chomp
      end

      # `save`: exactly one source — `--from FILE|-`, `--value V` (repeatable), or a piped stdin.
      private def self.cmd_wordlist_save(args : Array(String)) : Nil
        format = :text
        from : String? = nil
        values = [] of String
        overwrite = false
        db_path : String? = nil
        project_name : String? = nil
        payload_from = PayloadFromFlags.new
        pf_specs = [] of PayloadFrom::Spec
        positional = parse_args(args, "gori run wordlist save") do |p|
          p.banner = "Usage: gori run wordlist save <name> [--from FILE|-] [--value V]... [options]\n\n" \
                     "Save a list under #{Paths.wordlists_dir}, atomically and owner-only. The bytes\n" \
                     "are kept exactly (a blank or `#` line stays a line), so a Fuzzer run sends what\n" \
                     "you saved. Source, exactly one of: --from FILE (`-` = stdin), one or more\n" \
                     "--value, a list piped on stdin, or --payload-from (values read from a project's\n" \
                     "captured data; needs --project/--db). Refuses to replace an existing list."
          p.on("--from=FILE", "Copy this file (`-` reads stdin)") { |v| from = v }
          p.on("--value=V", "One value (repeatable); a value cannot contain a line break") { |v| values << v }
          p.on("--overwrite", "Replace a list of that name if there is one") { overwrite = true }
          # The project's data into a GLOBAL list is an explicit act: it needs a named project, and
          # the sensitive opt-in is the same one `fuzz` and `mine` ask for.
          payload_from_flags(p, "gori run wordlist save", payload_from, "Save") { |spec| pf_specs << spec }
          p.on("--project=NAME", "Project --payload-from reads") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file --payload-from reads") { |v| db_path = v }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end
        name = positional.first? || abort "gori run wordlist save: expected a wordlist name"
        if msg = extra_positional_error(positional, "gori run wordlist save", "wordlist name")
          abort msg
        end
        refuse_orphan_payload_from_flags("gori run wordlist save", payload_from, !pf_specs.empty?)
        refuse_conflicting_save_sources(from, values, pf_specs, project_name || db_path)

        entry = begin
          wordlist_save_entry(name, from, values, pf_specs.map(&.apply(payload_from.policy)), overwrite, project_name, db_path)
        rescue ex : WordlistCatalog::Error
          wordlist_error("save", ex)
        end
        if format == :json
          puts JSON.build { |j| wordlist_entry_json(j, entry) }
        else
          puts "saved #{CLI::Output.term_safe(entry.name)} (#{CLI::Output.human_size(entry.bytes)}) → #{entry.path}"
        end
      end

      # The one source `save` was given, saved.
      private def self.wordlist_save_entry(name : String, from : String?, values : Array(String),
                                           specs : Array(PayloadFrom::Spec), overwrite : Bool,
                                           project_name : String?, db_path : String?) : WordlistCatalog::Entry
        if src = from
          wordlist_save_from(name, src, overwrite)
        elsif !specs.empty?
          wordlist_save_from_project(name, specs, overwrite, project_name, db_path)
        elsif !values.empty?
          WordlistCatalog.save_values(name, values, overwrite: overwrite)
        elsif !STDIN.tty?
          WordlistCatalog.save_io(name, STDIN, overwrite: overwrite)
        else
          abort "gori run wordlist save: no source — give --from FILE, --value V, --payload-from, or pipe the list on stdin"
        end
      end

      # Exactly one source. `--project`/`--db` only make sense with `--payload-from`, and are refused
      # otherwise rather than ignored.
      private def self.refuse_conflicting_save_sources(from : String?, values : Array(String),
                                                       pf_specs : Array(PayloadFrom::Spec), project : String?) : Nil
        if [!from.nil?, !values.empty?, !pf_specs.empty?].count(true) > 1
          abort "gori run wordlist save: --from, --value and --payload-from name more than one source — pick one"
        end
        return unless pf_specs.empty? && project
        abort "gori run wordlist save: --project/--db select the project --payload-from reads, and none was given"
      end

      # Values read out of the project (`--payload-from`), saved as a global list. Both halves are
      # the operator's explicit choice: the project is named (there is no ambient default here) and
      # sensitive values stay out unless `--payload-from-sensitive` said otherwise. A value that
      # cannot be one line of the file — it holds a CR or LF — is left out AND counted, because the
      # file format cannot carry it (the same values `fuzz --payload-from` would send verbatim).
      private def self.wordlist_save_from_project(name : String, specs : Array(PayloadFrom::Spec), overwrite : Bool,
                                                  project_name : String?, db_path : String?) : WordlistCatalog::Entry
        WordlistCatalog.check_name!(name) # refuse a bad name before the project is opened
        store = open_payload_from_store("gori run wordlist save", specs, !!(project_name || db_path), project_name, db_path) ||
                abort("gori run wordlist save: --payload-from needs a project to read")
        values = [] of String
        seen = Set(String).new
        reports = [] of PayloadFrom::Report
        begin
          specs.each do |spec|
            resolved = begin
              PayloadFrom.resolve(store, spec)
            rescue ex : PayloadFrom::Error
              store.close
              abort "gori run wordlist save: #{ex.message}"
            end
            reports << resolved.report
            resolved.values.each { |v| values << v if seen.add?(v) }
          end
        ensure
          store.close
        end
        note_payload_from("gori run wordlist save", reports)
        lines, skipped = WordlistCatalog.one_per_line(values)
        if skipped > 0
          STDERR.puts "gori run wordlist save: #{Gori.plural(skipped, "value")} left out — a wordlist file holds one value per line, " \
                      "and #{skipped == 1 ? "it contains" : "they contain"} a line break"
        end
        WordlistCatalog.save_values(name, lines, overwrite: overwrite)
      end

      private def self.wordlist_save_from(name : String, src : String, overwrite : Bool) : WordlistCatalog::Entry
        if src == "-"
          if msg = stdin_terminal_error(STDIN, what: "gori run wordlist save", noun: "list",
               hint: stdin_pipe_hint("gori run wordlist save #{name}", flag: "--from -", producer: "generator"))
            abort msg
          end
          return WordlistCatalog.save_io(name, STDIN, overwrite: overwrite)
        end
        WordlistCatalog.save_file(name, src, overwrite: overwrite)
      end

      private def self.cmd_wordlist_rename(args : Array(String)) : Nil
        format = :text
        overwrite = false
        positional = [] of String
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run wordlist rename <old> <new> [--overwrite] [options]"
          p.on("--overwrite", "Replace a list already named <new>") { overwrite = true }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort CLI.unknown_option_message("gori run wordlist rename", f, p) }
          p.missing_option { |f| abort "gori run wordlist rename: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run wordlist rename: expected <old> <new>\n#{parser}" unless positional.size == 2

        entry = begin
          WordlistCatalog.rename(positional[0], positional[1], overwrite: overwrite)
        rescue ex : WordlistCatalog::Error
          wordlist_error("rename", ex)
        end
        if format == :json
          puts JSON.build { |j| wordlist_entry_json(j, entry) }
        else
          puts "renamed #{CLI::Output.term_safe(positional[0])} → #{CLI::Output.term_safe(entry.name)}"
        end
      end

      # `delete` has no interactive prompt: `--yes` is the confirmation, and without it the
      # command says what it would have removed and refuses (the `history clear` shape).
      private def self.cmd_wordlist_delete(args : Array(String)) : Nil
        yes = false
        positional = parse_args(args, "gori run wordlist delete") do |p|
          p.banner = "Usage: gori run wordlist delete <name> --yes [options]\n\n" \
                     "Delete a list from the catalog. A symlink is removed, never the file it names."
          p.on("--yes", "Actually delete it (required — there is no interactive prompt here)") { yes = true }
        end
        name = positional.first? || abort "gori run wordlist delete: expected a wordlist name"
        if msg = extra_positional_error(positional, "gori run wordlist delete", "wordlist name")
          abort msg
        end

        begin
          info = WordlistCatalog.entry(WordlistCatalog.check_name!(name)) ||
                 raise WordlistCatalog::Error.new(WordlistCatalog::Error::Reason::NotFound,
                   "no wordlist named #{name.inspect} in #{Paths.wordlists_dir}", name)
          unless yes
            abort "gori run wordlist delete: refusing to delete #{name.inspect} " \
                  "(#{CLI::Output.human_size(info.bytes)}) without --yes"
          end
          WordlistCatalog.delete(name)
          puts "deleted #{CLI::Output.term_safe(name)}"
        rescue ex : WordlistCatalog::Error
          wordlist_error("delete", ex)
        end
      end
    end
  end
end
