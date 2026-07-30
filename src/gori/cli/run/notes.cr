# `gori run notes` — read the project's notes (list, show one, or --all),
# or write them (create, delete). Notes are addressed by their 1-based list
# position <n> (the same number `notes <n>` and the listing show), not the
# internal stable id.
module Gori
  module CLI
    module Run
      private def self.cmd_notes(args : Array(String)) : Nil
        case args.first?
        when "create"       then cmd_notes_create(args[1..])
        when "delete", "rm" then cmd_notes_delete(args[1..])
        when "list"         then cmd_notes_read(args[1..])
        else                     cmd_notes_read(args)
        end
      end

      private def self.cmd_notes_read(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        all = false
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run notes [<n>] [options]\n\n" \
                     "List the project's notes; with <n> (1-based) print that note in full, " \
                     "or --all to print them all.\n\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run notes create [--text TEXT] [options]\n" \
                     "  gori run notes delete <n> [options]"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--all", "Print every note in full instead of the one-line list") { all = true }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run notes: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run notes: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run notes: too many arguments (expected at most one note number)" if positional.size > 1
        index = parse_note_index(positional.first?)
        abort "gori run notes: <n> and --all are mutually exclusive" if index && all

        store = open_store(resolve_read_project(project_name, db_path))
        doc = begin
          Notes.load(store)
        ensure
          store.close
        end

        if n = index
          abort "gori run notes: no note ##{n} (this project has #{doc.size} note#{doc.size == 1 ? "" : "s"})" unless n <= doc.size
          show_note(doc, n - 1, format)
        elsif all
          show_all_notes(doc, format)
        else
          list_notes(doc, format)
        end
      end

      private def self.cmd_notes_create(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        text : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run notes create [--text TEXT] [options]\n\n" \
                     "Create a note. Body comes from --text, else the positional args,\n" \
                     "else STDIN (e.g. `some-tool | gori run notes create`)."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--text=TEXT", "Note body (else positional args, else STDIN)") { |v| text = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run notes create: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run notes create: missing value for #{f}" }
        end
        parser.parse(args)

        body = text || (positional.empty? ? nil : positional.join(' '))
        body ||= STDIN.gets_to_end unless STDIN.tty?
        abort "gori run notes create: no note text (use --text, positional args, or pipe via STDIN)" if body.nil? || body.empty?

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          # Merge the append into the freshly-read doc instead of a blind load→overwrite,
          # so a concurrent writer's notes (a TUI editing the same project) aren't reverted.
          # Same reconcile the TUI save path uses (Notes.merge): `mine` is only the new note,
          # so every persisted note is kept and just the delta is added.
          persisted = Notes.load(store)
          new_id = persisted.next_id
          merged = Notes.merge(persisted, [Notes::NoteEntry.new(new_id, body)], Set(Int64).new,
            persisted.size, persisted.next_id + 1)
          # set_setting returns false when the write didn't commit (store busy/locked):
          # don't claim success then — same guard as issues/rewriter/project mutations.
          unless store.set_setting(Notes::DOCS_KEY, Notes.serialize(merged.cur, merged.notes, merged.next_id))
            store.close
            abort "gori run notes create: project is busy (write did not commit) — try again"
          end
          puts "Note ##{merged.size} created."
        ensure
          store.close
        end
      end

      private def self.cmd_notes_delete(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run notes delete <n> [options]\n\n" \
                     "Delete the note at 1-based list position <n> (as shown by `notes`)."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run notes delete: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run notes delete: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run notes delete: missing <n>" if positional.empty?
        abort "gori run notes delete: too many arguments (expected one note number)" if positional.size > 1
        n = parse_note_index(positional.first).not_nil!

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          persisted = Notes.load(store)
          unless n <= persisted.size
            store.close
            abort "gori run notes delete: no note ##{n} (this project has #{persisted.size} note#{persisted.size == 1 ? "" : "s"})"
          end
          # Delete by the note's STABLE id (not its list position) and merge, so a concurrent
          # writer's other notes aren't clobbered by a blind overwrite. See Notes.merge.
          target_id = persisted.notes[n - 1].id
          merged = Notes.merge(persisted, [] of Notes::NoteEntry, Set{target_id},
            persisted.cur, persisted.next_id)
          unless store.set_setting(Notes::DOCS_KEY, Notes.serialize(merged.cur, merged.notes, merged.next_id))
            store.close
            abort "gori run notes delete: project is busy (write did not commit) — try again"
          end
          puts "Note ##{n} deleted."
        ensure
          store.close
        end
      end

      private def self.parse_note_index(arg : String?) : Int32?
        return nil unless arg
        n = arg.to_i?
        abort "gori run notes: invalid note number '#{arg}' (expected a positive integer)" unless n && n > 0
        n
      end

      # Print one note (`idx` 0-based) in full: its exact text, or a full JSON object.
      private def self.show_note(doc : Notes::Doc, idx : Int32, format : Symbol) : Nil
        entry = doc.notes[idx]
        text = entry.text
        if format == :json
          puts CLI::Output.note_object_json(idx, entry, current: doc.cur == idx, with_text: true)
        else
          STDOUT.puts Issues::Export.scrub_controls(text)
        end
      end

      private def self.show_all_notes(doc : Notes::Doc, format : Symbol) : Nil
        if format == :json
          puts CLI::Output.notes_array_json(doc, with_text: true)
        elsif doc.empty?
          STDERR.puts "no notes"
        else
          doc.texts.each_with_index do |text, i|
            puts "" if i > 0
            puts "=== note #{i + 1}: #{CLI::Output.note_label(i, text)}#{doc.cur == i ? " *" : ""} ==="
            STDOUT.puts text
          end
        end
      end

      private def self.list_notes(doc : Notes::Doc, format : Symbol) : Nil
        if format == :json
          puts CLI::Output.notes_array_json(doc, with_text: false)
        elsif doc.empty?
          STDERR.puts "no notes"
        else
          doc.texts.each_with_index { |text, i| puts CLI::Output.note_row_text(i, text, current: doc.cur == i) }
        end
      end
    end
  end
end
