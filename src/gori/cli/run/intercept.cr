# `gori run intercept` — inspect/drive the live intercept queue of a capturing TUI
# instance. Interceptor is TUI-only (a headless `gori run capture` never holds
# requests), so this is a script's window into a HUMAN's paused queue: read what's
# held, then forward/drop/edit it, or flip catch/filter/direction. Mirrors `gori
# mcp`'s intercept_* tools (src/gori/mcp/tools/intercept.cr) byte-for-byte — same
# bridge blob (Store#intercept_bridge, published by Runner#publish_intercept_bridge),
# same command-queue round-trip (Store#enqueue_intercept_command +
# Store#command_status), same liveness/ack-poll constants — so a script gets the
# same outcome whether it drives gori through the CLI or MCP.
module Gori
  module CLI
    module Run
      private def self.cmd_intercept(args : Array(String)) : Nil
        sub = args.first?
        case sub
        when "-h", "--help" then print_intercept_help
        when "get"          then cmd_intercept_get(args[1..])
        when "forward"      then cmd_intercept_forward(args[1..])
        when "drop"         then cmd_intercept_drop(args[1..])
        when "list"         then cmd_intercept_list(args[1..])
        when nil            then cmd_intercept_list(args)
        else                     cmd_intercept2(sub, args)
        end
      end

      # The second half of the subcommand `case` (split from cmd_intercept so each
      # method stays under the cyclomatic-complexity bar). `sub` is non-nil here.
      private def self.cmd_intercept2(sub : String?, args : Array(String)) : Nil
        case sub
        when "edit"      then cmd_intercept_edit(args[1..])
        when "enable"    then cmd_intercept_toggle(true, args[1..])
        when "disable"   then cmd_intercept_toggle(false, args[1..])
        when "filter"    then cmd_intercept_set_filter(args[1..])
        when "direction" then cmd_intercept_set_direction(args[1..])
        else
          if (s = sub) && s.starts_with?('-')
            cmd_intercept_list(args)
          else
            STDERR.puts "gori run intercept: unknown subcommand '#{sub}'"
            print_intercept_help
            exit 1
          end
        end
      end

      private def self.print_intercept_help : Nil
        puts <<-HELP
        gori run intercept — inspect/drive the live intercept queue of a capturing TUI instance

        Usage: gori run intercept [<subcommand>] [options]

        Requires an open TUI on this project with intercept catch on — Interceptor is
        TUI-only (a headless `gori run capture` never holds requests). Write subcommands
        round-trip through the project database and bounded-poll for the TUI's ack.

        Subcommands:
          list                                 List held items + intercept state (default)
          get <item-id>                        Full detail for one held item
          forward <item-id>                    Forward a held item byte-exact
          drop <item-id>                       Drop a held item (client gets a canned 502)
          edit <item-id> (--raw=… | --raw-file=PATH)   Forward with edited bytes
          enable                               Turn on live intercept catch
          disable                              Turn off live intercept catch
          filter <query>                       Set the conditional-intercept filter ("" clears)
          direction <both|request|response>    Set which leg(s) intercept holds

        Examples:
          gori run intercept
          gori run intercept get 3 --format json
          gori run intercept forward 3
          gori run intercept edit 3 --raw-file edited.txt
          gori run intercept direction request

        See 'gori run intercept <subcommand> --help' for more.
        HELP
      end

      # --- bridge state (read side) -------------------------------------------

      # Parse the bridge blob the capturing TUI publishes (nil when no capturing
      # instance is live / has ever published). Mirrors MCP's intercept_bridge_state.
      private def self.intercept_bridge_state(store : Store) : Hash(String, JSON::Any)?
        raw = store.intercept_bridge
        return nil unless raw
        JSON.parse(raw).as_h?
      rescue
        nil
      end

      # A capturing instance is "live" only if its bridge says capturing AND the
      # heartbeat is recent — otherwise a queued command would never be applied.
      INTERCEPT_LIVE_MS   = 10_000_i64
      INTERCEPT_ACK_POLLS =         30
      INTERCEPT_ACK_SLEEP = 100.milliseconds

      private def self.intercept_live?(bridge : Hash(String, JSON::Any)) : Bool
        return false unless bridge["capturing"]?.try(&.as_bool?)
        hb = bridge["heartbeat_ms"]?.try(&.as_i64?) || 0_i64
        hb > 0 && (Time.utc.to_unix_ms - hb) < INTERCEPT_LIVE_MS
      end

      private def self.cmd_intercept_list(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        include_sensitive = false

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run intercept [list] [options]"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--include-sensitive", "Show Authorization/Cookie/etc header values instead of [REDACTED]") { include_sensitive = true }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run intercept: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run intercept: missing value for #{f}" }
        end
        parser.parse(args)

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          bridge = intercept_bridge_state(store)
          unless bridge
            unavailable = "no capturing gori instance is publishing intercept state (open the project's TUI to intercept)"
            if format == :json
              puts(JSON.build { |j| j.object { j.field "available", false; j.field "reason", unavailable } })
            else
              STDERR.puts unavailable
            end
            return
          end

          token = bridge["session_token"]?.try(&.as_s?) || ""
          now_ms = Time.utc.to_unix_ms
          items = token.empty? ? [] of Store::HeldRow : store.intercept_held(token)
          # Stamp viewed_ms so the capturing instance's auto-forward reaper sees this
          # script is watching (mirrors MCP intercept_list).
          store.touch_intercept_held(token, items.map(&.item_id), now_ms) unless items.empty?
          emit_intercept_list(bridge, items, include_sensitive, now_ms, format)
        ensure
          store.close
        end
      end

      private def self.emit_intercept_list(bridge : Hash(String, JSON::Any), items : Array(Store::HeldRow),
                                           include_sensitive : Bool, now_ms : Int64, format : Symbol) : Nil
        live = intercept_live?(bridge)
        enabled = bridge["enabled"]?.try(&.as_bool?) || false
        direction = bridge["direction"]?.try(&.as_s?) || "both"
        filter = bridge["filter"]?.try(&.as_s?) || ""
        if format == :json
          puts(JSON.build do |j|
            j.object do
              j.field "available", true
              j.field "capturing", live
              j.field "enabled", enabled
              j.field "direction", direction
              j.field "filter", filter
              j.field "heartbeat_age_seconds", (bridge["heartbeat_ms"]?.try(&.as_i64?).try { |hb| hb > 0 ? (now_ms - hb) // 1000 : nil })
              j.field "pending_count", items.size
              j.field("items") { j.array { items.each { |r| MCP::Serialize.intercept_item_row(j, r, include_sensitive, now_ms) } } }
            end
          end)
        else
          STDERR.puts "intercept: #{live ? "LIVE" : "not live (stale heartbeat)"} · catch #{enabled ? "ON" : "OFF"} · direction #{direction}"
          STDERR.puts "filter: #{filter.empty? ? "(none)" : filter}"
          if items.empty?
            puts "No items currently held."
          else
            items.each do |r|
              _, body = MCP::Serialize.head_and_body(r.raw)
              # method/scheme/host/target are parsed off the wire (a held request's request
              # line / Host header, or a held response) — CLI::Output.term_safe neutralizes
              # any ANSI/OSC/CSI escapes before they hit the live terminal (see its doc
              # comment; same discipline as flow_row_text/print_message_text).
              method = CLI::Output.term_safe(r.method.ljust(6))
              scheme = CLI::Output.term_safe(r.scheme)
              host = CLI::Output.term_safe(r.host)
              target = CLI::Output.term_safe(r.target)
              puts "##{r.item_id}  [#{r.kind}]  #{method} #{scheme}://#{host}#{target}  (#{body.size}b body)"
            end
          end
        end
      end

      private def self.cmd_intercept_get(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        include_sensitive = false
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run intercept get <item-id> [options]"
          p.on("--project=NAME", "Project to read (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to read") { |v| db_path = v }
          p.on("--include-sensitive", "Also include the full raw message base64 (unredacted)") { include_sensitive = true }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run intercept get: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run intercept get: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run intercept get: missing <item-id>" if positional.empty?
        abort "gori run intercept get: too many arguments (expected one <item-id>)" if positional.size > 1
        item_id = positional[0].to_i64? || abort("gori run intercept get: invalid item id '#{positional[0]}'")

        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          bridge = intercept_bridge_state(store)
          abort "gori run intercept get: no capturing gori instance is publishing intercept state" unless bridge
          token = bridge["session_token"]?.try(&.as_s?) || ""
          row = token.empty? ? nil : store.intercept_held(token).find { |r| r.item_id == item_id }
          abort "gori run intercept get: held item #{item_id} is not currently held (already forwarded/dropped, or never held)" unless row
          now_ms = Time.utc.to_unix_ms
          store.touch_intercept_held(token, [row.item_id], now_ms)

          if format == :json
            puts(JSON.build { |j| MCP::Serialize.intercept_item_detail(j, row, include_sensitive, now_ms) })
          else
            head, body = MCP::Serialize.head_and_body(row.raw)
            redacted = MCP::Serialize.redact_head(head, include_sensitive)
            puts CLI::Output.term_safe_multiline(redacted).rstrip
            unless body.empty?
              puts ""
              puts "[#{body.size} bytes of body — use --format json --include-sensitive for the raw bytes]"
            end
          end
        ensure
          store.close
        end
      end

      # Enqueue one command against the project's live capturing instance, then
      # bounded-poll its acknowledgement — mirrors MCP's enqueue_intercept/
      # await_intercept_ack so a script gets a real outcome rather than assuming
      # success on a write that may have been dropped or never drained.
      private def self.enqueue_intercept(project_name : String?, db_path : String?, verb : String, *,
                                         item_id : Int64? = nil, bytes : Bytes? = nil, arg : String? = nil) : {String, String?}
        project = resolve_read_project(project_name, db_path)
        store = open_store(project)
        begin
          bridge = intercept_bridge_state(store)
          unless bridge && intercept_live?(bridge)
            abort "gori run intercept: no live capturing gori instance is draining intercept commands (open the project's TUI with intercept on)"
          end
          token = bridge["session_token"]?.try(&.as_s?)
          id = store.enqueue_intercept_command(token, verb, item_id: item_id, bytes: bytes, arg: arg)
          abort "gori run intercept: could not enqueue intercept command (store write dropped); retry" if id == 0
          await_intercept_ack(store, id)
        ensure
          store.close
        end
      end

      private def self.await_intercept_ack(store : Store, id : Int64) : {String, String?}
        INTERCEPT_ACK_POLLS.times do
          if st = store.command_status(id)
            return st unless st[0] == "pending"
          end
          sleep INTERCEPT_ACK_SLEEP
        end
        ms = (INTERCEPT_ACK_POLLS * INTERCEPT_ACK_SLEEP.total_milliseconds).to_i
        abort "gori run intercept: command not confirmed within #{ms}ms — the capturing instance may be busy; retry"
      end

      private def self.emit_intercept_ack(status : String, detail : String?, format : Symbol) : Nil
        ok = !status.in?("no_such_item", "stale", "error")
        if format == :json
          puts(JSON.build { |j| j.object { j.field "status", status; j.field "ok", ok; j.field "detail", detail } })
        else
          puts "#{status}#{detail ? ": #{detail}" : ""}"
        end
        exit 1 unless ok
      end

      private def self.cmd_intercept_forward(args : Array(String)) : Nil
        item_id, project_name, db_path, format = parse_intercept_item_args(args, "forward")
        status, detail = enqueue_intercept(project_name, db_path, "forward", item_id: item_id)
        emit_intercept_ack(status, detail, format)
      end

      private def self.cmd_intercept_drop(args : Array(String)) : Nil
        item_id, project_name, db_path, format = parse_intercept_item_args(args, "drop")
        status, detail = enqueue_intercept(project_name, db_path, "drop", item_id: item_id)
        emit_intercept_ack(status, detail, format)
      end

      # Shared option/positional parsing for the single-<item-id> write subcommands
      # (forward/drop) so their bodies stay tiny and identical in shape.
      private def self.parse_intercept_item_args(args : Array(String), verb : String) : {Int64, String?, String?, Symbol}
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run intercept #{verb} <item-id> [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run intercept #{verb}: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run intercept #{verb}: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run intercept #{verb}: missing <item-id>" if positional.empty?
        abort "gori run intercept #{verb}: too many arguments (expected one <item-id>)" if positional.size > 1
        item_id = positional[0].to_i64? || abort("gori run intercept #{verb}: invalid item id '#{positional[0]}'")
        {item_id, project_name, db_path, format}
      end

      private def self.cmd_intercept_edit(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        raw : String? = nil
        raw_file : String? = nil
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run intercept edit <item-id> (--raw=RAW | --raw-file=PATH) [options]\n\n" \
                     "Forward a held item with EDITED bytes: the full replacement wire message\n" \
                     "(whichever leg — request or response — is held). Bytes are forwarded\n" \
                     "VERBATIM (no $KEY expansion); Content-Length is resynced to the new body."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--raw=RAW", "Verbatim replacement wire message") { |v| raw = v }
          p.on("--raw-file=PATH", "Read the replacement wire message from FILE") { |v| raw_file = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run intercept edit: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run intercept edit: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run intercept edit: missing <item-id>" if positional.empty?
        abort "gori run intercept edit: too many arguments (expected one <item-id>)" if positional.size > 1
        item_id = positional[0].to_i64? || abort("gori run intercept edit: invalid item id '#{positional[0]}'")

        content = if f = raw_file
                    abort "gori run intercept edit: --raw-file '#{f}' is not readable" unless File.exists?(f) && !File.directory?(f)
                    File.read(f)
                  elsif r = raw
                    r
                  else
                    abort "gori run intercept edit: --raw or --raw-file is required"
                  end
        abort "gori run intercept edit: replacement message must not be empty" if content.empty?

        # Byte-level CRLF normalize, not `.gsub(/\r?\n/, "\r\n")` — content may be
        # an arbitrary binary body read from --raw-file (invalid UTF-8), which a
        # Regex subject cannot accept and would crash on.
        wire = Env.normalize_crlf(content.to_slice)
        bytes = Fuzz::ContentLength.sync(wire, add_when_missing: true)
        status, detail = enqueue_intercept(project_name, db_path, "forward_edit", item_id: item_id, bytes: bytes)
        emit_intercept_ack(status, detail, format)
      end

      private def self.cmd_intercept_toggle(enable : Bool, args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        action = enable ? "enable" : "disable"

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run intercept #{action} [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run intercept #{action}: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run intercept #{action}: missing value for #{f}" }
        end
        parser.parse(args)

        status, detail = enqueue_intercept(project_name, db_path, "toggle", arg: enable ? "true" : "false")
        emit_intercept_ack(status, detail, format)
      end

      private def self.cmd_intercept_set_filter(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run intercept filter <query> [options]\n\n" \
                     "Set the conditional-intercept filter (a gori-QL-like query that narrows\n" \
                     "which requests/responses are held). Pass an empty string to clear it."
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run intercept filter: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run intercept filter: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run intercept filter: missing <query> (pass \"\" to clear)" if positional.empty?
        abort "gori run intercept filter: too many arguments (expected one <query>)" if positional.size > 1

        status, detail = enqueue_intercept(project_name, db_path, "set_filter", arg: positional[0])
        emit_intercept_ack(status, detail, format)
      end

      private def self.cmd_intercept_set_direction(args : Array(String)) : Nil
        db_path : String? = nil
        project_name : String? = nil
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run intercept direction <both|request|response> [options]"
          p.on("--project=NAME", "Project to update (default: most-recently-active)") { |v| project_name = v }
          p.on("--db=PATH", "Explicit SQLite db file to update") { |v| db_path = v }
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run intercept direction: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run intercept direction: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run intercept direction: missing <both|request|response>" if positional.empty?
        abort "gori run intercept direction: too many arguments (expected one)" if positional.size > 1
        dir = positional[0].strip.downcase
        abort "gori run intercept direction: invalid direction '#{positional[0]}' (expected both|request|response)" unless dir.in?("both", "request", "response")

        status, detail = enqueue_intercept(project_name, db_path, "set_direction", arg: dir)
        emit_intercept_ack(status, detail, format)
      end
    end
  end
end
