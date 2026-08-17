# `gori run oast` — listen for out-of-band callbacks (interactsh & friends); print the
# payload, then stream decrypted hits. `listen` is ad-hoc; `list`/`resume`/`release` act on
# the sessions the project persists (the TUI's RESUME LISTENER rows).
module Gori
  module CLI
    module Run
      # `gori run oast` — headless out-of-band listener (interactsh & friends). `listen` is
      # store-free and ad-hoc: register a payload, print it, then stream decrypted callbacks.
      # `providers` and the session verbs (`list`/`resume`/`release`) read the project store.
      private def self.cmd_oast(args : Array(String)) : Nil
        # `providers` is the one OAST subcommand that touches the project store, so it must be
        # dispatched BEFORE strip_project_flags eats the --project/--db it actually needs.
        # Match it ANYWHERE in the argv, not just at args[0] — `gori run oast --project=X
        # providers` is the natural invocation and is exactly the one that carries the flag.
        if i = args.index("providers")
          return cmd_oast_providers(args[...i] + args[(i + 1)..])
        end
        # Same reason for the session verbs: `list` / `resume` / `release` are the OAST
        # subcommands that read and write the PROJECT's persisted sessions, so they must be
        # dispatched before strip_project_flags eats the --project/--db they need. Unlike the
        # `providers` scan above this one walks positionally and skips a flag's VALUE, so
        # `gori run oast --project list resume 7` resumes in the project NAMED "list".
        if pos = oast_subcommand_index(args)
          case sub = args[pos]
          when "list", "resume", "release"
            return cmd_oast_session_verb(sub, args[...pos] + args[(pos + 1)..])
          end
        end

        filtered = strip_project_flags(args)
        case sub = filtered.first?
        when "presets"           then oast_presets
        when "listen"            then oast_listen(filtered[1..])
        when nil, "-h", "--help" then oast_help
        else
          STDERR.puts "gori run oast: unknown subcommand '#{sub}'"
          oast_help
          exit 1
        end
      end

      # oast is a store-free ad-hoc listener, so --project/--db are accepted-and-ignored for
      # CLI consistency (the top-level help says most subcommands take them). Strip BOTH the
      # attached `--project=X` and the space-separated `--project X` forms — the old
      # reject-token-only left a stray value that then parsed as the subcommand ("unknown
      # subcommand 'myproj'").
      private def self.strip_project_flags(args : Array(String)) : Array(String)
        out = [] of String
        i = 0
        while i < args.size
          a = args[i]
          if a == "--project" || a == "--db"
            i += 2 # skip the flag AND its value
          elsif a.starts_with?("--project=") || a.starts_with?("--db=")
            i += 1 # attached form is a single token
          else
            out << a
            i += 1
          end
        end
        out
      end

      # Index of the first POSITIONAL token — the subcommand — skipping options and the
      # separate value of the two that take one. nil when the argv is all flags.
      private def self.oast_subcommand_index(args : Array(String)) : Int32?
        i = 0
        while i < args.size
          a = args[i]
          if a == "--project" || a == "--db"
            i += 2
          elsif a.starts_with?('-')
            i += 1
          else
            return i
          end
        end
        nil
      end

      private def self.oast_help : Nil
        puts <<-HELP
          Usage: gori run oast <subcommand>
            listen      Register an OAST payload and stream incoming callbacks (ad-hoc)
            list        List this project's SAVED listening sessions
            resume      Resume a saved session and stream its callbacks
            release     Deregister a saved session server-side (its callbacks stay)
            presets     List the built-in public providers
            providers   Manage SAVED providers (list, add, update, enable/disable, delete)

          `listen` is store-free: its registration ends with the process. `list`/`resume`/
          `release` act on the sessions the TUI OAST tab persists, the same rows its RESUME
          LISTENER picker shows. Run `gori run oast listen -h` for listen options.
          HELP
      end

      # --- saved providers (the TUI OAST tab's Providers sub-tab) ---------------------------
      #
      # `listen` takes an ad-hoc --provider/--server/--token per run; these are the persisted
      # entries an operator configures once (a private interactsh server and its token, say)
      # and reuses. Only PROJECT entries are writable here — a global one lives in the user's
      # settings.json and is shared across every project.

      private def self.cmd_oast_providers(args : Array(String)) : Nil
        case sub = args.first?
        when "add"          then cmd_oast_provider_write(args[1..], update: false)
        when "update"       then cmd_oast_provider_write(args[1..], update: true)
        when "enable"       then cmd_oast_provider_enabled(args[1..], true)
        when "disable"      then cmd_oast_provider_enabled(args[1..], false)
        when "delete", "rm" then cmd_oast_provider_delete(args[1..])
        when "list"         then cmd_oast_providers_list(args[1..])
        else
          # Same guard, same reason as cmd_issues / cmd_links — see `verb_token?`.
          # `oast providers remove p_1` listed the providers and exited 0, deleting nothing.
          if verb_token?(sub)
            abort "gori run oast providers: unknown subcommand '#{sub}' " \
                  "(add, update, enable, disable, delete/rm, list)"
          end
          cmd_oast_providers_list(args)
        end
      end

      private def self.cmd_oast_providers_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        show_tokens = false
        format = :text
        leftover = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run oast providers [list] [options]\n\n" \
                     "List saved OAST providers. `id` is scope-qualified: p_<n> is this project's,\n" \
                     "g_<hex> is a global one from settings.json (read-only here)."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--show-tokens", "Print provider auth tokens instead of [REDACTED]") { show_tokens = true }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| leftover = before + after }
          p.invalid_option { |f| abort "gori run oast providers: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run oast providers: missing value for #{f}" }
        end
        parser.parse(args)
        refuse_list_leftovers(leftover, "oast providers",
          "add, update, enable, disable, delete/rm, list")

        store = open_store(resolve_read_project(project_name, db_path))
        configs = begin
          Oast.provider_configs(store)
        ensure
          store.close
        end

        if format == :json
          puts(JSON.build do |j|
            j.array do
              configs.each do |c|
                j.object do
                  j.field "id", c.key
                  j.field "name", c.name
                  j.field "kind", c.kind
                  j.field "host", c.host
                  j.field "scope", c.scope
                  j.field "enabled", c.enabled
                  j.field "token", c.token.nil? ? nil : (show_tokens ? c.token : "[REDACTED]")
                end
              end
            end
          end)
          return
        end
        if configs.empty?
          STDERR.puts "no saved OAST providers (add one with `gori run oast providers add`)"
          return
        end
        configs.each do |c|
          tok = c.token.nil? ? "" : "  token=#{show_tokens ? c.token : "[REDACTED]"}"
          puts "#{c.enabled ? "[on ]" : "[off]"} #{c.key.ljust(12)} #{c.kind.ljust(13)} #{c.name.ljust(24)} #{c.host}#{tok}"
        end
      end

      private def self.cmd_oast_provider_write(args : Array(String), *, update : Bool) : Nil
        verb = update ? "update" : "add"
        db_path : String? = nil
        project_name : String? = nil
        id : String? = nil
        name : String? = nil
        # Nilable sentinels, not defaults: on `update` a field the caller did not mention must
        # keep its stored value. Replacing the whole row instead would silently drop the
        # provider's auth TOKEN whenever someone edited only the name.
        kind_s : String? = nil
        host : String? = nil
        token : String? = nil
        enabled : Bool? = nil

        parser = OptionParser.new do |p|
          p.banner = update ? "Usage: gori run oast providers update <id> [options]\n\nFields you do not pass keep their current value." \
                               : "Usage: gori run oast providers add --name=N [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--name=NAME", "Display name#{update ? "" : " (required)"}") { |v| name = v }
          p.on("--kind=KIND", "interactsh (default) | custom-http | webhook.site | BOAST | postbin") { |v| kind_s = v }
          p.on("--host=URL", "Server/base URL (defaults to the kind's public preset)") { |v| host = v }
          p.on("--token=TOK", "Provider auth token") { |v| token = v }
          p.on("--enabled", "Turn the provider on") { enabled = true }
          p.on("--disabled", "Turn the provider off") { enabled = false }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| id = (before + after).first? }
          p.invalid_option { |f| abort "gori run oast providers #{verb}: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run oast providers #{verb}: missing value for #{f}" }
        end
        parser.parse(args)

        # An unparseable kind would be stored verbatim and then never match a ProviderKind at
        # listen time — the provider would simply never fire. Refuse it here.
        kind = kind_s.try do |k|
          Oast::ProviderKind.parse?(k) || abort("gori run oast providers #{verb}: unknown --kind '#{k}'")
        end

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          if update
            oast_provider_apply_update(store, oast_provider_row_id(store, id, verb),
              name, kind, host, token, enabled)
          else
            oast_provider_apply_add(store, name, kind, host, token, enabled)
          end
        ensure
          store.close
        end
      end

      # Update path: every field the caller omitted keeps its stored value.
      private def self.oast_provider_apply_update(store : Store, row : Int64, name : String?,
                                                  kind : Oast::ProviderKind?, host : String?,
                                                  token : String?, enabled : Bool?) : Nil
        existing = store.oast_providers.find { |p| p.id == row }
        abort "gori run oast providers update: no project OAST provider with id 'p_#{row}'" if existing.nil?
        # The store answers whether the write COMMITTED, and this was the one provider verb
        # that dropped it — `enable/disable`, `delete` and `add` in this same file all check
        # theirs. So a busy/locked project printed "updated." over a provider whose host or
        # token was unchanged, and the next `oast` listen went out against the old one.
        ok = store.update_oast_provider(row,
          name.try(&.strip).presence || existing.name,
          kind.try(&.label) || existing.kind,
          host.try(&.strip).presence || existing.host,
          # See the MCP twin: `--token=` with an empty value is a CLEAR, not an omission.
          token.nil? ? existing.token : token.strip.presence,
          enabled.nil? ? existing.enabled? : enabled)
        abort "gori run oast providers update: NOT applied (project busy) — the provider is unchanged" unless ok
        puts "OAST provider p_#{row} updated."
      end

      private def self.oast_provider_apply_add(store : Store, name : String?,
                                               kind : Oast::ProviderKind?, host : String?,
                                               token : String?, enabled : Bool?) : Nil
        abort "gori run oast providers add: --name is required" if name.nil? || name.empty?
        k = kind || Oast::ProviderKind::Interactsh
        h = host.try(&.strip).presence || Oast::Presets.all.find { |p| p.kind == k }.try(&.host)
        abort "gori run oast providers add: --host is required for #{k.label} (it has no default preset)" if h.nil?
        id = store.insert_oast_provider(name, k.label, h, token.try(&.strip).presence,
          enabled.nil? ? true : enabled, store.oast_providers.size)
        abort "gori run oast providers add: failed to persist the provider (store busy or unwritable)" if id == 0
        puts "OAST provider 'p_#{id}' created."
      end

      private def self.cmd_oast_provider_enabled(args : Array(String), enabled : Bool) : Nil
        verb = enabled ? "enable" : "disable"
        db_path : String? = nil
        project_name : String? = nil
        leftover = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run oast providers #{verb} <id>"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| leftover = before + after }
          p.invalid_option { |f| abort "gori run oast providers #{verb}: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run oast providers #{verb}: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run oast providers #{verb}: too many arguments (expected one <id>, got: #{leftover.join(" ")})" if leftover.size > 1
        id = leftover.first?

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          row = oast_provider_row_id(store, id, verb)
          abort "gori run oast providers: enable/disable NOT applied (project busy)" unless store.set_oast_provider_enabled(row, enabled)
          puts "OAST provider p_#{row} is now #{enabled ? "enabled" : "disabled"}."
        ensure
          store.close
        end
      end

      private def self.cmd_oast_provider_delete(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        leftover = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run oast providers delete <id>"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| leftover = before + after }
          p.invalid_option { |f| abort "gori run oast providers delete: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run oast providers delete: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run oast providers delete: too many arguments (expected one <id>, got: #{leftover.join(" ")})" if leftover.size > 1
        id = leftover.first?

        store = open_store(resolve_read_project(project_name, db_path))
        begin
          row = oast_provider_row_id(store, id, "delete")
          abort "gori run oast providers: NOT deleted (project busy) — the provider is unchanged" unless store.delete_oast_provider(row)
          puts "OAST provider p_#{row} deleted."
        ensure
          store.close
        end
      end

      # The PROJECT row id behind a "p_<n>" key, refusing a global one (settings.json, shared
      # across projects) and an id that names no row.
      private def self.oast_provider_row_id(store : Store, id : String?, verb : String) : Int64
        key = id
        abort "gori run oast providers #{verb}: <id> is required (see `gori run oast providers`)" if key.nil?
        if key.starts_with?("g_")
          abort "gori run oast providers #{verb}: '#{key}' is a GLOBAL provider (stored in settings.json, shared across projects) — it cannot be changed per project"
        end
        row = key.starts_with?("p_") ? key[2..].to_i64? : key.to_i64?
        abort "gori run oast providers #{verb}: malformed provider id '#{key}' (expected p_<n>)" if row.nil?
        abort "gori run oast providers #{verb}: no project OAST provider with id '#{key}'" unless store.oast_providers.any? { |p| p.id == row }
        row
      end

      # --- persisted sessions (the TUI OAST tab's RESUME LISTENER) --------------------------
      #
      # `listen` above is ad-hoc: it registers, prints a payload, and its registration dies
      # with the process. These three act on the sessions a PROJECT persists, so a payload
      # planted yesterday — the stored one that only fires on a nightly job, the mail a
      # back-office browser opens tomorrow — still has a listener to come home to. Resuming is
      # always an explicit act (P4): nothing here runs because a project was opened.

      private def self.cmd_oast_session_verb(verb : String, args : Array(String)) : Nil
        case verb
        when "list"    then cmd_oast_sessions_list(args)
        when "resume"  then cmd_oast_session_resume(args)
        when "release" then cmd_oast_session_release(args)
        end
      end

      private def self.cmd_oast_sessions_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        leftover = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run oast list [options]\n\n" \
                     "List this project's saved OAST sessions — the rows the TUI's RESUME\n" \
                     "LISTENER picker shows. Resume one with `gori run oast resume <id>`."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| leftover = before + after }
          p.invalid_option { |f| abort "gori run oast list: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run oast list: missing value for #{f}" }
        end
        parser.parse(args)
        refuse_list_leftovers(leftover, "oast", "list, resume, release")

        store = open_store(resolve_read_project(project_name, db_path))
        sessions = begin
          Oast::Sessions.list(store)
        ensure
          store.close
        end

        if format == :json
          puts(JSON.build do |j|
            j.array do
              sessions.each do |s|
                j.object do
                  j.field "id", s.id
                  j.field "provider", s.provider
                  j.field "provider_id", s.provider_key
                  j.field "kind", s.kind
                  j.field "payload_host", s.payload_host
                  j.field "server_url", s.server_url
                  j.field "hits", s.hits
                  j.field "created_at", s.created_at.to_rfc3339
                  j.field "last_poll_at", s.last_poll_at.try(&.to_rfc3339)
                end
              end
            end
          end)
          return
        end
        if sessions.empty?
          STDERR.puts "no saved OAST sessions (start one on the TUI OAST tab, or `gori run oast listen` ad-hoc)"
          return
        end
        sessions.each do |s|
          last = s.last_poll_at.try(&.to_local.to_s("%Y-%m-%d %H:%M")) || "never"
          puts "##{s.id.to_s.ljust(5)} #{s.provider.ljust(24)} #{s.kind.ljust(13)} " \
               "#{s.payload_host.ljust(34)} #{s.hits.to_s.rjust(5)} hits  " \
               "started #{s.created_at.to_local.to_s("%Y-%m-%d %H:%M")}  last poll #{last}"
        end
      end

      # Re-arm a saved session and stream its callbacks, persisting each one into the project
      # exactly as the TUI listener does — so a headless resume and the tab are collecting into
      # the same table, and either can pick the session up afterwards.
      private def self.cmd_oast_session_resume(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        id_arg : String? = nil
        interval = 5
        json = false
        once = false

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run oast resume <id> [options]\n\n" \
                     "Resume a saved session (see `gori run oast list`) and stream its\n" \
                     "callbacks. The registration is KEPT on exit — use `release` to drop it."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--interval=SEC", "Poll interval seconds (default 5)") { |v| interval = parse_count(v, "--interval") }
          p.on("--once", "Poll once and exit (no loop)") { once = true }
          p.on("--json", "Emit the payload and each callback as a JSON line (same shape as MCP)") { json = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| id_arg = (before + after).first? }
          p.invalid_option { |f| abort "gori run oast resume: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run oast resume: missing value for #{f}" }
        end
        parser.parse(args)

        id = oast_session_id(id_arg, "resume")
        store = open_store(resolve_read_project(project_name, db_path))
        failed =
          begin
            bound = oast_bind_session(store, id, "resume")
            http = Oast::HttpClient.new
            begin
              Oast::Sessions.resume(bound, http)
            rescue ex
              # `Provider#resume` raises deliberately: a resume that failed quietly would leave
              # a listener polling a correlation id the server has never heard of.
              abort "gori run oast resume: session ##{id} could not be resumed: #{ex.message}"
            end
            oast_stream_session(store, bound, http, id, interval, once, json)
          ensure
            store.close
          end
        # A --once run whose single poll FAILED must not exit 0 (same contract as `listen`).
        # Raised out here, not inside the block above, so the store still gets closed.
        exit 1 if failed
      end

      # The poll loop for a resumed session: dedup against what the row already holds, persist
      # every new interaction, and stamp last_poll_at so the cross-process liveness signal
      # (`OutOfBand::StoreMinter`) sees this listener the way it sees the TUI's. Returns true
      # when a `--once` poll errored. Never deregisters — resuming is not a lease.
      #
      # `io`/`err` default to the real streams and are parameters only so a spec can drive one
      # `--once` pass over a scripted `Oast::Http` and read back what was printed AND what was
      # persisted (the same seam idea as `oast_wait_or_stop`).
      private def self.oast_stream_session(store : Store, bound : Oast::Sessions::Bound,
                                           http : Oast::Http, id : Int64, interval : Int32,
                                           once : Bool, json : Bool,
                                           io : IO = STDOUT, err : IO = STDERR) : Bool
        label = bound.session.kind.label
        hits = store.oast_callback_count(id)
        payload = bound.provider.generate_payload(bound.session)
        if json
          io.puts Oast::Present.payload(payload, id, label).to_json
        else
          err.puts "resumed session ##{id} on #{bound.session.host} (#{bound.label}) — " \
                   "#{hits} callback#{hits == 1 ? "" : "s"} on file; payload:"
          io.puts payload
          err.puts "waiting for callbacks (Ctrl-C to stop)…" unless once
        end
        io.flush

        seen = Oast::Sessions.seen_uids(store, id)
        # Same trap-into-a-channel shape as `listen`, and for the same reason: without it the
        # interval sleep swallows Ctrl-C until the next tick. (--once polls exactly once, so it
        # keeps the default Ctrl-C = immediate-exit behavior and installs no trap.)
        stop = Channel(Nil).new(1)
        install_oast_stop_trap(stop) unless once
        once_failed = false
        loop do
          interactions = begin
            bound.provider.poll(http, bound.session)
          rescue ex
            err.puts "poll error: #{ex.message}"
            once_failed = true
            [] of Oast::Interaction
          end
          store.touch_oast_session(id)
          interactions.each do |i|
            next if seen.includes?(i.unique_id)
            seen << i.unique_id
            Oast::Sessions.record_callback(store, id, i)
            oast_emit_callback(io, i, label, json)
          end
          break if once
          break if oast_wait_or_stop(stop, interval.seconds)
        end
        once && once_failed
      end

      # One callback on the wire the operator reads it on: the same JSON shape MCP returns
      # under --json, the same tab-separated line `listen` prints otherwise.
      private def self.oast_emit_callback(io : IO, i : Oast::Interaction, label : String,
                                          json : Bool) : Nil
        if json
          io.puts Oast::Present.interaction(i, label).to_json
        else
          io.puts "#{i.at.to_rfc3339}  #{i.protocol}\t#{i.method || "-"}\t#{i.source_ip || "-"}\t#{i.full_id}"
        end
        io.flush
      end

      # Deregister a saved session's SERVER-side state. The row and every callback it collected
      # stay: this releases the listener, not the evidence.
      private def self.cmd_oast_session_release(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        leftover = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run oast release <id>\n\n" \
                     "Deregister the session's server-side state. Its stored callbacks stay,\n" \
                     "but payloads minted from it stop resolving."
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| leftover = before + after }
          p.invalid_option { |f| abort "gori run oast release: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run oast release: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run oast release: too many arguments (expected one <id>, got: #{leftover.join(" ")})" if leftover.size > 1

        id = oast_session_id(leftover.first?, "release")
        store = open_store(resolve_read_project(project_name, db_path))
        begin
          bound = oast_bind_session(store, id, "release")
          abort "gori run oast release: could not deregister session ##{id} (provider error) — payloads minted from it may still resolve" unless Oast::Sessions.release(bound, Oast::HttpClient.new)
          puts "released OAST session ##{id} — its #{store.oast_callback_count(id)} callback(s) stay."
        ensure
          store.close
        end
      end

      # `<id>` as the operator types it: `7`, or the `#7` `list` prints.
      private def self.oast_session_id(arg : String?, verb : String) : Int64
        raw = arg
        abort "gori run oast #{verb}: <id> is required (see `gori run oast list`)" if raw.nil?
        Oast::Sessions.parse_id(raw) ||
          abort("gori run oast #{verb}: malformed session id '#{raw}' (expected a number, as `gori run oast list` prints)")
      end

      private def self.oast_bind_session(store : Store, id : Int64, verb : String) : Oast::Sessions::Bound
        bound = Oast::Sessions.bind(store, id)
        if bound.is_a?(Oast::Sessions::Problem)
          abort "gori run oast #{verb}: #{Oast::Sessions.message_for(bound, id)}"
        end
        bound
      end

      private def self.oast_presets : Nil
        Oast::Presets.all.each do |p|
          puts "#{p.kind.label.ljust(13)} #{p.name.ljust(34)} #{p.host}"
        end
      end

      private def self.oast_listen(args : Array(String)) : Nil
        provider = "interactsh"
        server : String? = nil
        token : String? = nil
        interval = 5
        json = false
        once = false
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run oast listen [options]"
          p.on("--provider=KIND", "interactsh (default) | custom-http | webhook.site | BOAST | postbin") { |v| provider = v }
          p.on("--server=URL", "Provider server/base URL (default: the provider's public preset)") { |v| server = v }
          p.on("--token=TOK", "Optional provider auth token") { |v| token = v }
          p.on("--interval=SEC", "Poll interval seconds (default 5)") { |v| interval = parse_count(v, "--interval") }
          p.on("--once", "Poll once and exit (no loop)") { once = true }
          p.on("--json", "Emit each callback as a JSON line (same shape as MCP)") { json = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          # Without these, OptionParser's default raises straight past `Run.dispatch` (rescues
          # IO::Error) and `CLI.run` (rescues Gori::Error) to `main`, printing a Crystal
          # backtrace — the form cli.cr's own top-level rescue calls "the least usable there
          # is". `gori run oast listen --bogus` already did it; narrowing the global version
          # scan just routed `--version` there too. This parser was fixed first and read as the
          # only one; a later sweep found eleven more parsers taking a `=VALUE` flag with no
          # `missing_option`, so the invariant is now pinned by a source grep over every parser
          # under src/gori/cli/ (spec/cli/run/option_parser_missing_option_spec.cr).
          p.invalid_option { |f| abort "gori run oast listen: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run oast listen: missing value for #{f}" }
        end
        parser.parse(args)

        kind = Oast::ProviderKind.parse?(provider)
        unless kind
          STDERR.puts "gori run oast: unknown provider '#{provider}'"
          exit 1
        end
        host = server || Oast::Presets.all.find { |pr| pr.kind == kind }.try(&.host)
        unless host
          STDERR.puts "gori run oast: --server is required for #{kind.label}"
          exit 1
        end
        prov = Oast::Provider.build(kind, host, token)
        http = Oast::HttpClient.new
        session = begin
          prov.register(http)
        rescue ex
          STDERR.puts "gori run oast: register failed: #{ex.message}"
          exit 1
        end
        payload = prov.generate_payload(session)
        STDERR.puts "listening on #{host} (#{kind.label}) — payload:"
        puts payload
        STDERR.puts "waiting for callbacks (Ctrl-C to stop)…" unless once
        seen = Set(String).new
        # Ctrl-C used to do nothing here: the poll loop trapped no signals, so despite the
        # "Ctrl-C to stop" hint only SIGTERM/SIGKILL ended the listener. Trap INT+TERM into
        # a buffered channel (matching gori run discover / App#install_signal_traps) and let
        # oast_wait_or_stop wake on it, so the interval sleep is interrupted promptly rather
        # than only at the next tick. (--once polls exactly once and returns, so it keeps the
        # default Ctrl-C = immediate-exit behavior and installs no trap.)
        stop = Channel(Nil).new(1)
        install_oast_stop_trap(stop) unless once
        once_failed = false
        begin
          loop do
            interactions = begin
              prov.poll(http, session)
            rescue ex
              STDERR.puts "poll error: #{ex.message}"
              once_failed = true
              [] of Oast::Interaction
            end
            interactions.each do |i|
              next if seen.includes?(i.unique_id)
              seen << i.unique_id
              if json
                puts Oast::Present.interaction(i, kind.label).to_json
              else
                puts "#{i.at.to_rfc3339}  #{i.protocol}\t#{i.method || "-"}\t#{i.source_ip || "-"}\t#{i.full_id}"
              end
              STDOUT.flush
            end
            break if once
            break if oast_wait_or_stop(stop, interval.seconds)
          end
        ensure
          # Help says listen's registration ends with the process. `--once` used to be
          # the only path that deregistered; Ctrl-C left a live interactsh/BOAST
          # registration whose payload still resolved with nobody watching.
          begin
            prov.deregister(http, session)
          rescue ex
            STDERR.puts "gori run oast: deregister failed: #{ex.message}"
          end
        end
        # A --once run whose single poll FAILED must not exit 0 — a scripted caller can't
        # otherwise tell "polled, found nothing" from "the poll errored". (#416)
        exit 1 if once && once_failed
      end

      # Block up to `interval`, returning true the instant a stop arrives (Ctrl-C via the
      # INT/TERM trap sends to `stop`) so the poll loop breaks promptly, or false on timeout
      # to poll again. Split out both to keep oast_listen readable and to be unit-testable
      # without delivering a real signal.
      # Second signal exits 130 instead of blocking in a full Channel#send (the
      # same hole install_interrupt_trap closed). Shared by listen and resume.
      private def self.install_oast_stop_trap(stop : Channel(Nil)) : Nil
        stopped = false
        escalate = -> {
          if stopped
            STDERR.puts "\ninterrupted again — exiting without finishing"
            exit 130
          end
          stopped = true
          select
          when stop.send(nil)
          else
          end
        }
        Signal::INT.trap { escalate.call }
        Signal::TERM.trap { escalate.call }
      end

      private def self.oast_wait_or_stop(stop : Channel(Nil), interval : Time::Span) : Bool
        select
        when stop.receive
          true
        when timeout(interval)
          false
        end
      end
    end
  end
end
