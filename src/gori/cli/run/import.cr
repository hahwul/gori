# `gori run import` — bulk-import captured flows into the project's History from a
# HAR export, a URL list, or an OpenAPI/Swagger spec (the CLI counterpart of the
# TUI's Import overlay). Exactly one source flag is required. Import WRITES flows,
# so it resolves its target like `discover` (--db create-or-reopen, else an existing
# project — never silently a fresh default).
module Gori
  module CLI
    module Run
      private def self.cmd_import(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        har : String? = nil
        oas : String? = nil
        urls : String? = nil

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run import (--har PATH | --oas PATH | --urls PATH) [options]\n\n" \
                     "Bulk-import flows into the project's History. Exactly one source is required:\n" \
                     "  --har   a browser/proxy HAR (HTTP Archive) export\n" \
                     "  --urls  a text file of URLs, one per line (# comments and blanks ignored)\n" \
                     "  --oas   request templates from an OpenAPI/Swagger spec (JSON or YAML)"
          p.on("--har=PATH", "Import a HAR (HTTP Archive) export") { |v| har = v }
          p.on("--oas=PATH", "Import an OpenAPI/Swagger spec (JSON or YAML)") { |v| oas = v }
          p.on("--urls=PATH", "Import a URL list (one URL per line)") { |v| urls = v }
          p.on("--project=NAME", "Project to import into (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to import into (created if absent)") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args do |rest, _|
            abort "gori run import: unexpected argument#{rest.size == 1 ? "" : "s"} #{rest.join(" ").inspect} — pass the file via --har PATH, --oas PATH, or --urls PATH" unless rest.empty?
          end
          p.invalid_option { |f| abort "gori run import: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run import: missing value for #{f}" }
        end
        parser.parse(args)

        kind, path = import_source(har, oas, urls)

        store = open_store(resolve_import_project(project_name, db_path))
        result = begin
          Import.import_file(store, kind, path)
        rescue ex : Gori::Error
          abort "gori run import: #{ex.message}"
        ensure
          store.close
        end

        emit_import_result(kind, path, result, format)
      end

      # Exactly one of --har/--oas/--urls. Zero or two+ is a clean usage error.
      private def self.import_source(har : String?, oas : String?, urls : String?) : {Symbol, String}
        chosen = [] of {Symbol, String}
        chosen << {:har, har} if har
        chosen << {:oas, oas} if oas
        chosen << {:urls, urls} if urls
        case chosen.size
        when 0 then abort "gori run import: a source is required — pass one of --har PATH, --oas PATH, or --urls PATH"
        when 1 then chosen.first
        else        abort "gori run import: pass exactly one source (got #{chosen.map(&.[0]).join(", ")})"
        end
      end

      # Import WRITES flows, so an explicit --db is create-or-reopened (like capture /
      # discover); without one it writes into an existing project (never silently
      # creates a default — use --db PATH or --project NAME for a brand-new target).
      private def self.resolve_import_project(project_name : String?, db_path : String?) : Project
        if path = db_path
          abort "gori run import: --db is a directory, not a file: #{path}" if Dir.exists?(path)
          parent = File.dirname(path)
          abort "gori run import: --db parent directory does not exist: #{parent}" unless Dir.exists?(parent)
          return Project.new(File.basename(parent), path)
        end
        resolve_read_project(project_name, nil)
      end

      private def self.emit_import_result(kind : Symbol, path : String, result : Import::Result, format : Symbol) : Nil
        puts(format == :json ? import_result_json(kind, path, result) : import_result_text(kind, path, result))
      end

      # Mirrors the TUI Import toast wording (runner.cr#apply_import) so the CLI and TUI
      # describe the same import the same way.
      private def self.import_result_text(kind : Symbol, path : String, result : Import::Result) : String
        s = "imported #{result.count} flow#{result.count == 1 ? "" : "s"} from #{import_label(kind)} · #{path}"
        s += " (#{result.skipped} #{result.skipped == 1 ? "entry" : "entries"} skipped)" if result.skipped > 0
        s
      end

      private def self.import_result_json(kind : Symbol, path : String, result : Import::Result) : String
        JSON.build do |j|
          j.object do
            j.field "kind", kind.to_s
            j.field "path", path
            j.field "count", result.count
            j.field "skipped", result.skipped
          end
        end
      end

      private def self.import_label(kind : Symbol) : String
        case kind
        when :har  then "HAR"
        when :urls then "URLs"
        when :oas  then "OpenAPI"
        else            kind.to_s
        end
      end
    end
  end
end
