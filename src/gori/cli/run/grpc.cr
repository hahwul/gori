require "../../protobuf/reflection"
require "../../discover/url"

# `gori run grpc` — the gRPC schema lens from the command line (#823/#827).
#
# `reflect` is the OUTBOUND half: it asks a target's `grpc.reflection.v1[alpha]` service for
# its descriptors and caches them in the project, so every flow on that target renders through
# real field names. It runs when the operator types it and never otherwise (P4), and it goes
# through the same `Gori::Outbound` gate every other active `gori run` command does — an
# out-of-scope target is refused before the dialer is reached.
#
# `schema` and `forget` touch nothing outside the project DB.
module Gori
  module CLI
    module Run
      @[Subcommand("grpc", help: [
        {"grpc reflect <url>", "Fetch a gRPC target's .proto descriptors by server reflection (ACTIVE) and cache them"},
        {"grpc schema", "What .proto schema this project loaded, and where each piece came from"},
        {"grpc forget", "Drop a cached reflection result (by target, or --all)"},
      ])]
      private def self.cmd_grpc(args : Array(String)) : Nil
        case sub = args.first?
        when "reflect"      then cmd_grpc_reflect(args[1..])
        when "schema"       then cmd_grpc_schema(args[1..])
        when "forget", "rm" then cmd_grpc_forget(args[1..])
        else
          # The read is the default — `gori run grpc` and `gori run grpc --project=x` both
          # print what is loaded, the same shape `gori run links` uses. A first token that
          # LOOKS like a verb and is not one still aborts, so a typo'd `gori run grpc reflekt`
          # says so rather than quietly listing (see `verb_token?`).
          abort "gori run grpc: unknown subcommand '#{sub}' (reflect, schema, forget/rm)" if verb_token?(sub)
          cmd_grpc_schema(args)
        end
      end

      private def self.cmd_grpc_reflect(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        allow_unscoped = false
        insecure = false
        timeout : Time::Span? = nil
        format = :text
        url : String? = nil

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run grpc reflect URL\n\n" \
                     "Ask a gRPC target's server-reflection service for its descriptors and cache\n" \
                     "them in the project. `grpc.reflection.v1` is tried first, `v1alpha` second.\n" \
                     "The cache is what every later flow on this target renders through — nothing\n" \
                     "re-fetches on its own.\n\n" \
                     "URL is the target origin: https://api.test:443 (the path is ignored)."
          p.on("--project=NAME", "Project to use (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file") { |v| db_path = v }
          p.on("--allow-unscoped", "Send even when the target is outside the project scope") { allow_unscoped = true }
          p.on("-k", "--insecure-upstream", "Do not verify the upstream TLS certificate") { insecure = true }
          p.on("--timeout=SECONDS", "Per-operation timeout (default: the project's io timeout)") do |v|
            n = v.to_f?
            abort "gori run grpc reflect: invalid --timeout '#{v}'" if n.nil? || n <= 0
            timeout = n.seconds
          end
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| url = one_positional(before, after, "gori run grpc reflect", "URL") }
          p.invalid_option { |f| abort "gori run grpc reflect: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run grpc reflect: missing value for #{f}" }
        end
        parser.parse(args)

        raw = url
        abort "gori run grpc reflect: a target URL is required (e.g. https://api.test:443)" if raw.nil? || raw.empty?
        parts = Gori::Discover::Url.parse(raw) ||
                abort("gori run grpc reflect: '#{raw}' is not an http(s) URL with a host")

        # The gate first, and its store separately from the one the cache is written through:
        # `project_outbound` hands its READ connection to the Outbound so the scope keeps
        # reloading, and that connection cannot take the write.
        outbound = project_outbound(project_name, db_path, allow_unscoped)
        client = Gori::Protobuf::Reflection::Client.new(outbound,
          scheme: parts.scheme, host: parts.host, port: parts.port,
          verify: !insecure, timeout: timeout,
          overrides: cli_host_overrides(project_name, db_path, nil))
        outcome = begin
          client.fetch
        ensure
          outbound.close
        end

        if outcome.refused?
          # Same exit code and the same wording shape as every other Layer-1/2 refusal on
          # this surface: the refusal is the answer, not an error in gori.
          abort "gori run grpc reflect: #{outcome.error}"
        end

        # The WRITE store is opened only when there is something to save. A failed fetch must
        # not take the project's writer lock (#752: an idle writer next to a capturing gori is
        # the condition worth avoiding), and there is nothing to write on that path anyway.
        committed = true
        if (set = outcome.descriptor_set) && outcome.ok?
          store = open_store(resolve_read_project(project_name, db_path))
          begin
            committed = Gori::Protobuf::Schemas.adopt(store, client.target, outcome.service,
              outcome.services.size, outcome.files, set)
          ensure
            store.close
          end
        end

        if format == :json
          puts(JSON.build do |j|
            j.object do
              j.field "target", client.target
              j.field "ok", outcome.ok?
              j.field "service", outcome.service
              j.field "version", outcome.version
              j.field "services", outcome.services
              j.field "files", outcome.files
              j.field "saved", outcome.ok? && committed
              j.field "schema", Gori::Protobuf::Schemas.status
              j.field "notes", outcome.notes
              j.field "error", outcome.error
            end
          end)
        else
          if err = outcome.error
            # The notes go to STDERR alongside the failure, not swallowed: "3 of 4 symbols
            # answered NOT_FOUND" is what turns "returned no descriptors" into something the
            # operator can act on.
            outcome.notes.each { |n| STDERR.puts "  ! #{n}" }
            abort "gori run grpc reflect: #{err}"
          end
          puts "#{client.target} · #{outcome.version} · #{outcome.services.size} service(s) · #{outcome.files} descriptor file(s)"
          outcome.services.each { |s| puts "  #{s}" }
          outcome.notes.each { |n| puts "  ! #{n}" }
          puts "schema: #{Gori::Protobuf::Schemas.status}"
          puts "  ! not saved (project busy); it reverts when you reopen this project" unless committed
        end
        exit(outcome.ok? ? 0 : 1)
      end

      private def self.cmd_grpc_schema(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        leftover = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run grpc [schema]\n\n" \
                     "What .proto schema this project has loaded, and where each piece came from —\n" \
                     "a descriptor-set file, or a reflection fetch against a target.\n\n" \
                     "Or run with a subcommand:\n" \
                     "  gori run grpc reflect URL   fetch descriptors by server reflection (ACTIVE)\n" \
                     "  gori run grpc forget TARGET drop a cached reflection result (`rm` is accepted)"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| leftover = before + after }
          p.invalid_option { |f| abort "gori run grpc schema: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run grpc schema: missing value for #{f}" }
        end
        parser.parse(args)
        # The flag-first route (`gori run grpc --project=X reflect …`) hands the READ command
        # the verb it discarded. Refusing it is what keeps a mutation from no-op'ing with a
        # success status — the twelfth-plus caller of the seam that exists for exactly that.
        refuse_list_leftovers(leftover, "grpc", "reflect, schema, forget/rm", "schema")

        # `open_store` already published this project's schema (`Schemas.load_project`), so
        # what is printed here is exactly what every other surface renders through.
        store = open_store(resolve_read_project(project_name, db_path), read_only: true)
        reflections = store.grpc_reflections
        store.close

        sources = Gori::Protobuf::Schemas.sources
        if format == :json
          puts(JSON.build do |j|
            j.object do
              j.field "spec", Gori::Protobuf::Schemas.spec
              j.field "status", Gori::Protobuf::Schemas.status
              j.field "sources" do
                j.array do
                  sources.each do |src|
                    j.object do
                      j.field "origin", src.origin.to_s.downcase
                      j.field "path", src.path
                      j.field "messages", src.messages
                      j.field "methods", src.methods
                      j.field "error", src.error
                    end
                  end
                end
              end
              j.field "reflections" do
                j.array do
                  reflections.each do |r|
                    j.object do
                      j.field "target", r.target
                      j.field "service", r.service
                      j.field "fetched_at", r.fetched_at
                      j.field "services", r.services
                      j.field "files", r.files
                      j.field "bytes", r.descriptor.size
                    end
                  end
                end
              end
            end
          end)
          return
        end

        spec = Gori::Protobuf::Schemas.spec
        puts "descriptor path: #{spec.empty? ? "(#{Gori::Paths.protos_dir})" : spec}"
        puts "schema: #{Gori::Protobuf::Schemas.status}"
        if sources.empty?
          puts "no sources loaded"
          return
        end
        sources.each do |src|
          origin = src.origin.reflection? ? "reflection" : "file"
          if err = src.error
            puts "  #{origin} #{src.path}: #{err}"
          else
            puts "  #{origin} #{src.path}: #{src.messages} message(s), #{src.methods} rpc(s)"
          end
        end
      end

      private def self.cmd_grpc_forget(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        all = false
        target : String? = nil

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run grpc forget TARGET | --all\n\n" \
                     "Drop a cached reflection result. TARGET is the value `gori run grpc schema`\n" \
                     "prints (scheme://host:port). Nothing else is touched — a descriptor-set FILE\n" \
                     "is unloaded by clearing the path in Project settings."
          p.on("--project=NAME", "Project to use (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file") { |v| db_path = v }
          p.on("--all", "Forget every cached reflection target") { all = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| target = one_positional(before, after, "gori run grpc forget", "TARGET") }
          p.invalid_option { |f| abort "gori run grpc forget: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run grpc forget: missing value for #{f}" }
        end
        parser.parse(args)

        chosen = target
        if all
          abort "gori run grpc forget: pass a TARGET or --all, not both" if chosen
        else
          abort "gori run grpc forget: a TARGET (or --all) is required" if chosen.nil? || chosen.empty?
        end

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          known = store.grpc_reflections.map(&.target)
          if (t = chosen) && !known.includes?(t)
            # A typo'd target must not print "forgotten" — that reads as "the schema is gone"
            # while the lens is still in place.
            abort "gori run grpc forget: no cached reflection for '#{t}'#{known.empty? ? "" : " (have: #{known.join(", ")})"}"
          end
          committed = Gori::Protobuf::Schemas.forget(store, chosen)
          puts chosen ? "forgot #{chosen}" : "forgot #{known.size} reflected target(s)"
          puts "schema: #{Gori::Protobuf::Schemas.status}"
          puts "  ! not saved (project busy); it comes back when you reopen this project" unless committed
        ensure
          store.close
        end
      end
    end
  end
end
