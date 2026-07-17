# `gori run notes` — read the project's notes (list, show one, or --all).
module Gori
  module CLI
    module Run
      private def self.cmd_notes(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        all = false
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run notes [<n>] [options]\n\nList the project's notes; with <n> (1-based) print that note in full, or --all to print them all."
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
          STDOUT.puts text
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
