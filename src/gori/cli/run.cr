require "option_parser"
require "json"
require "base64"
require "../config"
require "../paths"
require "../settings"
require "../env"
require "../app"
require "../store"
require "../project"
require "../project_registry"
require "../ql"
require "../scope"
require "../host_overrides"
require "../sitemap"
require "../proxy/codec/content_decode"
require "../repeater/engine"
require "../repeater/h2_engine"
require "../repeater/ws_engine"
require "../repeater/flow_request"
require "../repeater/diff"
require "../repeater/minimize"
require "../repeater/message_lines"
require "../fuzz"
require "../decoder"
require "../miner"
require "../sequencer"
require "../authorize/plan"
require "../discover"
require "../discover/adapters"
require "../oast/provider_config"
require "../oast/sessions"
require "../probe/passive"
require "../probe/group"
require "../notes"
require "../issues_export"
require "../links"
require "../import"
require "../session_from_flow"
require "../export/curl"
require "../export/python_requests"
require "../export/js_fetch"
require "../export/go_http"
require "../export/httpie"
require "../export/csrf_poc"
require "./output"
require "./run/subcommand"
require "./run/interrupt"
require "./run/capture"
require "./run/history"
require "./run/repeater"
require "./run/repeater_minimize"
require "./run/compare"
require "./run/diff"
require "./run/intercept"
require "./run/fuzz_args"
require "./run/fuzz"
require "./run/fuzz_saved"
require "./run/mine"
require "./run/sequence"
require "./run/authorize"
require "./run/session"
require "./run/discover"
require "./run/oast"
require "./run/sitemap"
require "./run/import"
require "./run/probe"
require "./run/notes"
require "./run/issues"
require "./run/links"
require "./run/jwt"
require "./run/cookie"
require "./run/decoder"
require "./run/grpc"
require "./run/rewriter"
require "./run/colormarker"
require "./run/views"
require "./run/project"

module Gori
  module CLI
    # `gori run <subcommand>` — the non-interactive CLI. Scripts the same project
    # data the TUI works on, built directly on the Store / Repeater / Session APIs
    # (NOT the verb system, whose ExecContext is ~60 UI-action methods that only
    # make sense in front of a terminal). Read subcommands open the store read-only
    # and never take the capture lock, so they're safe to run alongside a live
    # capturing instance (SQLite WAL; #752).
    module Run
      def self.dispatch(args : Array(String)) : Nil
        route_logs_to_stderr
        dispatch_subcommand(args)
      rescue ex : IO::Error
        # `gori run … | head` (or any reader that closes early) breaks the STDOUT
        # pipe; a well-behaved Unix filter exits quietly on EPIPE rather than
        # dumping an IO::Error backtrace. Re-raise anything that isn't a broken pipe.
        # (Kept as a thin wrapper around the generated dispatch_subcommand; see the
        # Subcommand registry below.)
        raise ex unless ex.os_error == Errno::EPIPE
        exit 0
      end

      # STDOUT on these commands is DATA — a flow listing, a sitemap tree, `--format json` being
      # piped into `jq`. Nothing had pointed the root logger anywhere, so it sat on Crystal's
      # default STDOUT backend and any `Log.warn` in the code these commands run landed in the
      # middle of that data. Reproduced with `OpenLock`'s "held by a destructive operation"
      # warning: the operator got a raw timestamped log line on STDOUT and the clean sentence on
      # STDERR, the same failure said twice on two streams, one of which a pipe was reading.
      #
      # STDERR is where the other non-TUI surfaces already put it (`gori mcp`,
      # `App#run_capture`), so this is the read side joining them rather than a new policy. Not
      # in `dispatch_subcommand`: `run capture` calls `setup_logging` itself and this must not
      # be the thing that decides for it, but it must be in place before ANY subcommand runs.
      private def self.route_logs_to_stderr : Nil
        ::Log.setup(:info, ::Log::IOBackend.new(STDERR))
      rescue
        # A logger that cannot be configured is not a reason to refuse the command; the worst
        # case is the behaviour that shipped.
      end

      # --- Subcommand registry ----------------------------------------------------
      #
      # Generated from the `@[Subcommand]` annotations (run/subcommand.cr) on the `cmd_*`
      # entry points, once every `run/*.cr` reopen has been parsed: the name → handler
      # dispatch and the `gori run -h` table both derive from the same declarations, so a
      # subcommand is declared once, next to its body, and adding one touches only its own
      # file. Running order is definition order, which is the `require "./run/…"` order at
      # the top of this file — that list IS the help page's order.
      macro finished
        {% cmds = @type.class.methods.select(&.annotation(Subcommand)) %}

        private def self.dispatch_subcommand(args : Array(String)) : Nil
          Settings.load # global env vars (and other persisted defaults) for all subcommands
          # No args / -h / --help all print help. `args[1..]` is only reached in the named
          # branches, where args[0] matched a subcommand string (so args is non-empty and the
          # tail slice is safe).
          case sub = args.first?
          when nil, "-h", "--help" then print_help
          {% for m in cmds %}
            when {{ m.annotation(Subcommand).args.splat }} then {{ m.name }}(args[1..])
          {% end %}
          else
            STDERR.puts "gori run: unknown subcommand '#{sub}'"
            print_help
            exit 1
          end
        end

        # `gori run -h` rows: {name column, description}, one or more per subcommand.
        SUBCOMMANDS = [
          {% for m in cmds %}
            {% for row in m.annotation(Subcommand)[:help] %}
              {{ row }},
            {% end %}
          {% end %}
        ]
      end

      # Left column width for `gori run -h` subcommand names (longest: "project host-override").
      SUBCMD_COL_W = 22

      private def self.print_help : Nil
        puts "gori run — non-interactive CLI (script the proxy / history / repeater)"
        puts ""
        puts "Usage: gori run <subcommand> [options]"
        puts ""
        puts "Subcommands:"
        SUBCOMMANDS.each do |name, desc|
          gap = SUBCMD_COL_W - name.size
          gap = 1 if gap < 1
          puts "  #{name}#{" " * gap}#{desc}"
        end
        puts ""
        puts "Most read subcommands accept --project NAME or --db PATH; with neither they"
        puts "use the most-recently-active project. See 'gori run <subcommand> --help'."
      end

      # --- shared helpers ----------------------------------------------------

      # Is a subcommand's first token a VERB, as opposed to a flag or nothing at all?
      #
      # A `case args.first?` that ends in `else <the read command>` treats an unrecognized verb
      # as the default read, which is how `gori run issues remove 1` printed the issue list and
      # exited 0 having deleted nothing, and how `gori run links remove …` listed instead of
      # unlinking. Both are mutations that silently no-op with a SUCCESS status — the worst
      # failure mode for a surface scripts consume. So the `else` branch asks this first and
      # rejects a verb it does not know, while a leading flag (`--project x`, meaning "list")
      # and an empty argv still fall through to the read command.
      #
      # Only applicable to the verb-ONLY subcommands. The ones taking a bare positional —
      # `history`/`probe`/`sitemap` (a QL query), `notes` (`<n>`), `decoder` (a chain),
      # `repeater`/`show`/`fuzz` (an id) — legitimately receive a non-flag first token as DATA,
      # and reject a bad verb downstream when validating it.
      #
      # `rewriter`, `project` and `intercept` still hand-roll this same `starts_with?('-')` test
      # beside their own `case` (7 sites). Routing them through here is worth doing, but it
      # changes how they treat an empty-string token, so it wants its own change rather than
      # riding along with a bug fix.
      private def self.verb_token?(sub : String?) : Bool
        !sub.nil? && !sub.empty? && !sub.starts_with?('-')
      end

      # The one positional a command takes, or a clean refusal — the shape the rest of this
      # surface already uses (`repeater minimize`, `notes delete`, `colormarker color rm`,
      # `views add`, … all say "too many arguments (expected one …)").
      #
      # Four commands instead spelled `unknown_args { |b, a| x = (b + a).first? }`, which keeps
      # the first token and DROPS the rest in silence: `gori run oast providers update 3 4
      # --name=x` renamed provider 3, ignored 4, and exited 0 with a success line naming one
      # provider — from which the operator cannot tell that the other was never touched. Same
      # for `oast resume 1 2`, `grpc reflect URL1 URL2` and `grpc forget A B`. A dropped
      # argument that leaves a SUCCESS status is the failure mode a scripted surface can least
      # afford, which is why every other command here refuses it.
      #
      # Takes both halves of `unknown_args` for the reason the colormarker list documents: a
      # bare word after `--` lands in `after`, and reading only `before` would lose it.
      private def self.one_positional(before : Array(String), after : Array(String),
                                      prefix : String, what : String) : String?
        all = before + after
        if msg = extra_positional_error(all, prefix, what)
          abort msg
        end
        all.first?
      end

      # The same guard for the sites that keep the ARRAY (because they read `.first?` later, or
      # feed it to a `||` that offers a flag as the other spelling). Six commands collected
      # `before + after` and then read `positional.first?` with nothing in between, which drops
      # a second token exactly as `(before + after).first?` does and is not caught by grepping
      # for that shape: `gori run probe rules delete a b` deleted `a` and exited 0, and so did
      # `project scope update 3 4 --host=x`, `session add x y`, `rewriter preset add p q`,
      # `probe rules enable a b` and `probe mode passive active`. Four of those are mutations.
      private def self.one_positional_list(before : Array(String), after : Array(String),
                                           prefix : String, what : String) : Array(String)
        all = before + after
        if msg = extra_positional_error(all, prefix, what)
          abort msg
        end
        all
      end

      # The decision and the message, split from the abort so a spec can drive both — the same
      # split, for the same reason, as `list_leftover_error` and `two_targets_error`.
      def self.extra_positional_error(all : Array(String), prefix : String, what : String) : String?
        return nil if all.size <= 1
        "#{prefix}: too many arguments (expected one #{what}, got: #{all.join(" ")})"
      end

      # ZERO positionals: the same decision for a command whose every argument is a flag.
      #
      # `one_positional*` above covers the sites that KEEP the first token and drop the rest.
      # This is one step further down the same slope: three `repeater` subcommands installed
      # no `unknown_args` handler at all, and `OptionParser`'s default one is silent — so
      # `gori run repeater create -t URL -f req.txt extra.txt` built the session from
      # `req.txt`, discarded `extra.txt` and printed `Repeater session #N created
      # successfully.`, and `repeater h2 --target U --fields F stray` put the request on the
      # wire without a word. A dropped argument under a SUCCESS status is what a scripted
      # surface can least afford, which is the whole argument the twelve sites above make.
      #
      # `hint` names the flag the value belongs to, because a bare token here is almost always
      # something the operator meant to pass through one.
      def self.no_positional_error(all : Array(String), prefix : String, hint : String) : String?
        return nil if all.empty?
        "#{prefix}: unexpected argument#{all.size == 1 ? "" : "s"} #{all.join(" ").inspect} — #{hint}"
      end

      # Parse a command whose every argument is a flag, refusing any leftover word.
      #
      # A method rather than three copies of the idiom, because the subtle half is
      # `before + after`: a copy that keeps only `before` lets a bare word after `--` through
      # in silence, which is the same footgun `optionparser-unknown-args` was written about.
      # Installing the handler HERE makes the correct form the only form, and the call site
      # reads as what it means.
      private def self.parse_no_positionals(parser : OptionParser, args : Array(String),
                                            prefix : String, hint : String) : Nil
        positional = [] of String
        parser.unknown_args { |before, after| positional = before + after }
        parser.parse(args)
        if msg = no_positional_error(positional, prefix, hint)
          abort msg
        end
      end

      # `--db` and `--project` both name the target, so BOTH is not a preference to resolve —
      # it is two answers to one question, and silently keeping one is the failure this
      # surface is least able to survive.
      #
      # `--db` used to win without a word, so `gori run history --db "$DB" --project "$PROJ"`
      # with a `$PROJ` that does not even exist read `$DB` and exited 0 — the project name the
      # operator typed was never resolved, never checked, never mentioned. Harmless on a read;
      # `history delete -q … --yes`, `history clear --yes` and `project delete` take the same
      # pair of flags, and there the invisible winner decides which project gets emptied.
      #
      # A clean usage error rather than a warning, for the reason `import_source` gives about
      # two source flags: zero or two+ is a usage error, and a script's STDERR is exactly what
      # nobody reads.
      #
      # This IS a breaking change, and calling it a clarification would be dishonest: the old
      # behaviour was deterministic and documented ("--db=PATH — wins over everything"), so a
      # wrapper that pinned `--db` and passed a caller's `--project` through — `gr() { gori run
      # "$@" --db "$GORI_DB"; }` — worked and now aborts. It is taken deliberately, because the
      # same flag pair reaches `history delete --yes`, `history clear --yes` and `project
      # delete`, where the invisible winner decides which project gets emptied; a wrapper is
      # fixed by dropping one flag, and there is no equivalent repair for the wrong project.
      # The guide and the CLI reference both say so now.
      #
      # `presence`, so a `--project=` / `--db=` with nothing after the `=` is not counted as an
      # answer and the pair is left to the precedence below, resolving exactly as it did.
      private def self.refuse_two_targets(project_name : String?, db_path : String?,
                                          prefix : String = "gori run",
                                          project_flag : String = "--project",
                                          db_flag : String = "--db") : Nil
        if msg = two_targets_error(project_name, db_path, prefix, project_flag, db_flag)
          abort msg
        end
      end

      # The sentence, split from the abort so a spec can pin both the condition and the
      # wording — `refuse_two_targets` ends in `abort`, which a spec cannot drive. Same reason
      # `colormarker_rule_row` and `view_row` are public.
      #
      # The flag NAMES are parameters, not literals, because `gori run diff` reaches the same
      # resolver twice with `--from`/`--from-db` and `--to`/`--to-db` — it accepts neither
      # `--project` nor `--db`, so a hard-coded sentence told the operator to fix flags they
      # had not typed and could not type.
      def self.two_targets_error(project_name : String?, db_path : String?,
                                 prefix : String = "gori run",
                                 project_flag : String = "--project",
                                 db_flag : String = "--db") : String?
        return nil unless project_name.try(&.presence) && db_path.try(&.presence)
        "#{prefix}: pass #{db_flag} PATH or #{project_flag} NAME, not both " \
        "(#{db_flag} names the database file directly, so #{project_flag} #{project_name.inspect} would be ignored)"
      end

      # --db wins → else --project resolved via ProjectRegistry#find (exact short id
      # → exact dir slug → exact display name → unique id-prefix, all
      # case-insensitive) → else the most-recently-active project. Aborts when
      # nothing resolves. Routing through #find is what lets a read command finally
      # select by slug/id, not display name alone (parity with MCP --project).
      #
      # The default branch ANNOUNCES itself (see announce_default_project) — the whole
      # point of a default nobody typed is that it is invisible until it is wrong.
      private def self.resolve_read_project(project_name : String?, db_path : String?) : Project
        refuse_two_targets(project_name, db_path)
        if path = db_path
          abort "gori run: --db is not a readable file: #{path}" unless File.exists?(path) && !File.directory?(path)
          return Project.new(File.basename(File.dirname(path)), path)
        end
        registry = ProjectRegistry.new(Paths.projects_dir)
        if name = project_name
          if found = registry.find(name)
            return found
          end
          projects = registry.list
          abort "gori run: no project matching '#{name}'#{projects.empty? ? "" : " (have: #{projects.map(&.name).join(", ")})"}"
        end
        default = ProjectRegistry.default_of(registry.list)
        abort "gori run: no projects yet — capture some traffic first, or pass --db PATH" unless default
        announce_default_project(default)
        default
      end

      # Whether this process has already said which project it defaulted to.
      @@said_default_project = false

      # Where that notice goes. STDERR in production; a spec swaps in an `IO::Memory` to
      # assert on the line, because STDERR is a constant and cannot be replaced. Mirrors
      # `Settings.warning_io`, for the same reason.
      class_property default_project_io : IO? = STDERR

      # Say which project a `--project`-less command actually read — ONCE per process.
      #
      # Omitting `--project` is the common case and it silently picks the
      # most-recently-active project, so creating a project anywhere (another worktree, an
      # MCP `create_project`, a `gori run project create`) quietly re-aims every later
      # `gori run`. That is how `gori run history` printed "no flows" against a project
      # made a minute earlier while the one the operator meant still held 1609: the choice
      # was invisible, so the wrong project looked like an empty database.
      #
      # STDERR, so it stays out of a `--format json`/`jsonl`/`har` pipe on stdout — where
      # HAR already writes its own warnings — and is still seen by an operator watching a
      # terminal. Once per process because one command resolves its project up to three
      # times (the read itself, the host-override snapshot, the outbound scope load), and
      # three identical lines would read like three different projects.
      private def self.announce_default_project(project : Project) : Nil
        return if @@said_default_project
        @@said_default_project = true
        io = @@default_project_io
        return unless io
        io.puts "gori run: using project #{project.name} (most recently active) — " \
                "name another with --project NAME or --db PATH"
      end

      # Capture creates-or-reopens its target (unlike reads, which require an
      # existing one). --db targets an explicit database file instead of a project.
      private def self.resolve_capture_project(project_name : String?, db_path : String?) : Project
        refuse_two_targets(project_name, db_path, "gori run capture")
        if path = db_path
          # Catch the unopenable cases up front with a clean message — otherwise
          # SQLite raises a raw DB::ConnectionRefused backtrace deep in Session.open.
          abort "gori run capture: --db is a directory, not a file: #{path}" if Dir.exists?(path)
          parent = File.dirname(path)
          abort "gori run capture: --db parent directory does not exist: #{parent}" unless Dir.exists?(parent)
          return Project.new(File.basename(parent), path)
        end
        # create() rejects a name that slugifies to nothing (blank / punctuation-only)
        # with a Gori::Error, and Dir.mkdir_p raises a File::Error for an unusable slug
        # (e.g. longer than the filesystem's name limit). Surface both as a clean
        # `gori run capture:` message, like every other resolve_* path, instead of a raw
        # backtrace. (Non-ASCII names like "日本語" now get a hashed fallback slug in
        # ProjectRegistry#slugify, so they no longer land here.)
        name = project_name || "default"
        begin
          ProjectRegistry.new(Paths.projects_dir).create(name)
        rescue ex : Gori::Error
          abort "gori run capture: #{ex.message} (#{name.inspect})"
        rescue ex : File::Error
          abort "gori run capture: could not create project #{name.inspect}: #{ex.message}"
        end
      end

      # Read an operator-named input file, reporting a clean CLI error instead of a
      # backtrace. `File.exists? && !File.directory?` is NOT enough on its own: it passes
      # for a file that exists but cannot be opened (mode 000, an unreadable parent, a
      # foreign-owned path), and it is a TOCTOU window besides — the path can be deleted
      # between the check and the read. `File.read` then raises `File::AccessDeniedError` /
      # `File::NotFoundError`, and `File::Error < IO::Error` is re-raised by `Run.dispatch`
      # (which only absorbs EPIPE), so it escapes `CLI.run`'s `Gori::Error`-only rescue.
      # Mirrors the guard `run/rewriter.cr`'s `read_stub_response` already had. `stdin:` is
      # opt-in rather than the default so this stays a pure robustness change: only the one
      # caller that already spelled `-` as stdin keeps that meaning, and the flags that used
      # to reject `-` as an unreadable path go on rejecting it instead of quietly blocking
      # on a terminal read.
      private def self.read_input_file(path : String, what : String, *, stdin : Bool = false) : String
        return STDIN.gets_to_end if stdin && path == "-"
        abort "#{what}: not a readable file: #{path}" if File.directory?(path)
        File.read(path)
      rescue ex : File::Error
        abort "#{what}: cannot read '#{path}': #{ex.message}"
      end

      # Opening a non-SQLite file (or a path we can't read) raises deep in the driver;
      # turn that into a clean CLI error instead of an unhandled backtrace.
      # `read_only` for commands that never persist (history list/show, compare, issues
      # list, a scope load for Outbound). A `body:` query is a write — it drains FTS —
      # so those callers pass false. Every CLI store skips idle FTS: the process is
      # short-lived, and an idle indexer next to a capturing TUI is the #752 condition.
      private def self.open_store(project : Project, *, read_only : Bool = false) : Store
        store = Store.open(project.db_path,
          retention_flows: read_only ? Store::RETENTION_UNLIMITED : Settings.retention_flows,
          read_only: read_only,
          background_index: false)
        # The project's pinned upstream / dial timeouts / capture cap (#538). `bind: false`:
        # not one command routed through here LISTENS — `gori run capture` is the only
        # subcommand that binds and it opens its project through `Session.open` instead — so
        # the two bind keys are deliberately left out and the outbound/capture keys apply. Without this,
        # a project pinned to a jump host was dialled DIRECT by every `gori run` active
        # command, and an imported/replayed body was capped at the global limit.
        Settings.load_project_network(store, bind: false)
        # …and this project's gRPC schema, so `gori run history show --format json` names
        # the fields of a captured gRPC body exactly as the TUI pane does (#823).
        Protobuf::Schemas.load_project(store)
        Env.load_project(store)
        # The project's extract rules become `Env`'s send-time layer here too (#501) — with
        # NO values, because a binding lives in the memory of the gori that observed it and
        # nothing writes one to disk. That is not a gap to paper over: it is what makes a
        # headless send refuse with "unbound session binding $SESSION" instead of the much
        # less useful "unresolved env $SESSION" that an undeclared name would earn. One
        # syntax, one rule, and a refusal that names its gate on every surface.
        # …and the project's SESSION SLOTS alongside them, so a headless send resolves `$NAME`
        # out of the same table structure the TUI does. No slot is ACTIVE here (the pointer is
        # per-process and starts nil — see `SessionSlots`), so `gori run` behaves exactly as it
        # did: unscoped rules, global table, no overlay.
        Env.layer = Bindings.load(store, SessionSlots.load(store))
        # …and re-select whatever `--slot` chose, because THIS line just replaced the registry
        # holding the pointer. See `reapply_active_slot`.
        reapply_active_slot
        store
      rescue ex : DB::Error | SQLite3::Exception
        abort "gori run: cannot open database #{project.db_path}: " \
              "#{ex.message.presence || "not a valid SQLite database (or unreadable)"}" \
              "#{open_failure_hint(ex, project.db_path, read_only)}"
      end

      # What to add after SQLite's own sentence, for the two failures that are NOT what the
      # wrapper implies. Everything else keeps the wording it had, which is where a genuinely
      # unreadable or non-SQLite file still lands.
      #
      # A LOCKED project. A write subcommand opens for write and `Store.open` migrates, so a
      # peer holding the write lock (a TUI, a `gori run capture`, an MCP server) fails the open
      # after `busy_timeout=5000` with the bare words "database is locked" — printed under
      # "cannot open database <path>", which reads as a broken FILE. It is the opposite: the
      # file is fine and the condition clears by itself. Matched on the message, not
      # `SQLite3::Exception#code`, because this rescue also catches the `DB::Error` crystal-db
      # wraps some driver failures in, which carries the text but no code. The strings are
      # SQLite's own C-library constants, not locale-dependent.
      #
      # A READ-ONLY project, which cannot be recognised from the message at all: crystal-sqlite3
      # rescues everything `sqlite3_open_v2` + the pragmas raise and re-raises a bare
      # `DB::ConnectionRefused` — no message, NO cause (lib/sqlite3 connection.cr). So the
      # commonest write failure of all reaches here indistinguishable from a corrupt file, and
      # got told it was one: "not a valid SQLite database (or unreadable)" about a database that
      # is perfectly valid and that the very same operator can still READ. Since the driver
      # destroyed the reason, ask the filesystem for it — but only once the open has ALREADY
      # failed, never as a pre-flight gate, so nothing that works today starts being refused by
      # a `File::Info.writable?` that disagrees with the kernel (ACLs, a foreign mount).
      #
      # `read_only` opens are excluded because for them a non-writable file is not a fault.
      # Public for the reason `two_targets_error` is: its only caller ends in `abort`.
      def self.open_failure_hint(ex : Exception, db_path : String? = nil,
                                 read_only : Bool = false) : String
        msg = ex.message.to_s
        # `read_only` gates BOTH message branches, not just the filesystem tail below. A
        # read-only open can still surface either string — `Store.open` runs its pragmas before
        # `apply_query_only` — and both sentences were wrong for it: "read it with a read-only
        # subcommand" is what the operator just did, and "this subcommand writes" is false.
        if msg.includes?("is locked")
          return " — another gori (a TUI, a capture, or an MCP server) is writing to this project." \
                 " Nothing is wrong with the file; retry." if read_only
          return " — another gori (a TUI, a capture, or an MCP server) is writing to this project." \
                 " Nothing is wrong with the file: retry, or read it with a read-only subcommand."
        end
        if !read_only && (msg.includes?("readonly") || msg.includes?("read-only"))
          return " — this subcommand writes, and the file (or its directory) is not writable."
        end
        path = db_path
        return "" unless path && File.exists?(path)
        # The DIRECTORY, not just the file: a WAL database keeps `-wal` and `-shm` BESIDE it,
        # so SQLite has to create them there — which is why a read-only directory defeats even
        # a `read_only: true` open, while a read-only FILE in a writable directory reads fine.
        # Both were verified on the binary. That asymmetry is the whole reason the two branches
        # below ask different questions.
        dir_writable = File::Info.writable?(File.dirname(path))
        if read_only
          return "" if dir_writable
          return " — the DIRECTORY holding it is not writable, and SQLite's WAL mode must create" \
                 " `-shm`/`-wal` beside the file even to READ it. Copy the project somewhere writable."
        end
        return "" if dir_writable && File::Info.writable?(path)
        " — this subcommand writes, and the file (or its directory) is not writable."
      end

      # Does this QL string read `flows_fts`? Shape-only: no store, so it is safe to call
      # before `open_store` and decide whether the open has to be writable to drain.
      private def self.query_uses_fts?(query : String?) : Bool
        return false unless q = query
        return false if q.strip.empty?
        QL.parse(q, scope: QL::SCOPE_SHAPE_ONLY).uses_fts?
      rescue
        false
      end

      # Project host overrides for a CLI direct-dial command (fuzz/mine/sequence), loaded when
      # a project is in play — a flow-id reads from one, or --project/--db names one. Returns
      # nil for --request/stdin with no project (nothing to load; global Settings overrides
      # still apply inside Upstream.dial). Snapshots into memory, so the store can close.
      private def self.cli_host_overrides(project_name : String?, db_path : String?, flow_id : Int64?,
                                          repeater_id : Int64? = nil) : Gori::HostOverrides?
        return nil unless flow_id || repeater_id || project_name || db_path
        store = open_store(resolve_read_project(project_name, db_path), read_only: true)
        begin
          Gori::HostOverrides.load(store)
        ensure
          store.close
        end
      rescue
        nil
      end

      # The `Gori::Outbound` decision for a CLI direct-dial command (fuzz/mine/sequence/
      # repeater) — the one seam every active send on every surface passes through, and the
      # gate whose absence once let those tools fire at any host regardless of scope/Sandbox.
      # Loaded on the same trigger as cli_host_overrides (a project is in play).
      #
      # The read connection is handed to the Outbound rather than closed, so the rules keep
      # RELOADING for the length of the run: a mid-run EXCLUDE or Sandbox toggle (from the
      # TUI, or another `gori run project scope add`) stops an in-flight sweep, which the
      # previous start-time snapshot could never do. The caller releases it with
      # `outbound.close` once the command is done.
      #
      # With no project at all (--request/stdin), the result is an explicit
      # Unscoped(NoProject): permissive exactly as before, but a NAMED state instead of the
      # `scope ? ScopedBackend.new(sender, scope) : sender` nil that silently skipped the
      # gate entirely. A scope that fails to load must NOT fail OPEN (unlike overrides'
      # rescue-to-nil): a raise here becomes a clean fail-CLOSED abort — never a raw
      # backtrace, never a silently-unscoped run. (open_store already aborts on a bad DB.)
      private def self.optional_project_outbound(project_name : String?, db_path : String?, flow_id : Int64?,
                                                 allow_unscoped : Bool, repeater_id : Int64? = nil) : Gori::Outbound
        # ONLY fuzz/mine/sequence can genuinely run project-less (--request/stdin). Every
        # other caller reads its subject (a repeater session, a flow) out of a project and
        # must use project_outbound, or an omitted --project would silently drop the gate.
        # `repeater_id` is such a subject too (`fuzz --repeater`), so it forces the scoped path.
        return project_outbound(project_name, db_path, allow_unscoped) if flow_id || repeater_id || project_name || db_path
        # Standalone run: no project context at all, the same condition on which
        # cli_host_overrides skips loading overrides. `resolve_read_project` WOULD still
        # resolve a default project here, so this is the one `gori run` active path where the
        # active project's Sandbox and exclude rules do not apply. Say so on STDERR rather
        # than letting an ungated run look gated — binding a standalone run to the ambient
        # project instead is a product call, tracked as a follow-up on #354.
        STDERR.puts "gori run: no project in play (--request/stdin without --project/--db) — sending UNSCOPED; " \
                    "the active project's scope and Sandbox rules do NOT apply to this run"
        Gori::Outbound.cli(nil, allow_unscoped)
      end

      # The Outbound for a command that ALWAYS has a project in play — `gori run repeater`
      # resolves the most-recently-active project when --project/--db are omitted, so the
      # scope must be loaded from it either way (that default is exactly the case where
      # short-circuiting on "no --project given" would drop Sandbox containment).
      private def self.project_outbound(project_name : String?, db_path : String?,
                                        allow_unscoped : Bool) : Gori::Outbound
        store = open_store(resolve_read_project(project_name, db_path), read_only: true)
        scope = begin
          Gori::Scope.load(store)
        rescue ex
          store.close
          abort "gori run: could not load project scope (refusing to send unscoped): #{ex.message}"
        end
        Gori::Outbound.cli(scope, allow_unscoped, owns_store: store)
      end

      # Up-front (Layer-1) scope gate for the CLI direct-dial tools, with the policy owned
      # by the seam: an unconfigured project stays permissive, a configured one refuses an
      # out-of-scope target unless --allow-unscoped. This is only the soft include boundary;
      # Sandbox mode + explicit exclude rules are still enforced per-request by
      # `Fuzz::Sender`/`Repeater::Sender` regardless of --allow-unscoped.
      private def self.guard_outbound(outbound : Gori::Outbound, scheme : String, host : String,
                                      target : String, port : Int32, cmd : String) : Nil
        verdict = outbound.check_request(scheme, host, target, port)
        return unless verdict.blocked?
        outbound.close
        abort "#{cmd}: #{host} is out of the project scope — #{Gori::Outbound.remedy(verdict, "--allow-unscoped")}"
      end

      # ── the active session slot, headless ────────────────────────────────────────────
      #
      # `--slot NAME` is `gori run`'s activate. The TUI picks a slot once and every later send
      # goes out as it; the MCP server does the same across tool calls. A `gori run` process
      # sends and exits, so there is nothing for a persisted pointer to span — and persisting
      # one would be actively wrong (`SessionSlots`: a restored pointer resolves an empty
      # binding table, which is a 401 with no visible cause). The flag carries the same
      # intent at the only scope this surface has.
      #
      # Applied to `Env.layer`'s registry, which is the SAME object `Env.overlay_slot` and
      # `Env.expand_bindings` read — so naming a slot here changes both halves at once (the
      # header overlay AND which table `$NAME` resolves out of) instead of one of them.

      # The refusal for `--slot` with no project in play, which is a different fact from a
      # mistyped name and used to be indistinguishable from one. Mirrors
      # `BIND_FROM_NO_PROJECT`, for the same reason and on the same code path.
      SLOT_NO_PROJECT = "--slot: no project is in play (--request/stdin without --project/--db), " \
                        "so no session slots are loaded — name the project with --project NAME " \
                        "(or --db PATH)"

      # The slot `--slot NAME` selected, remembered for the whole process.
      #
      # It has to be remembered rather than merely applied once, because `open_store`
      # REPLACES `Env.layer` — and with it the slot registry — every time it is called, and a
      # command opens its project more than once: the flow read, the host-override snapshot,
      # and `project_outbound`'s own long-lived connection are three separate opens. A
      # one-shot activation therefore survived only until the next one, which is how
      # `--slot admin` could announce itself and then put no overlay on the wire at all.
      # `open_store` re-applies this, so the selection is independent of how many times a
      # command opens the project and in what order.
      @@active_slot : String? = nil

      # Select the send context for THIS process. Must run after the project is open
      # (`open_store` installs `Env.layer`) and BEFORE anything sends — including
      # `--bind-from`, whose replay fills the tables the rest of the run resolves against.
      private def self.activate_slot(name : String?, cmd : String) : Nil
        return unless name
        slots = Env.layer.as?(Gori::Bindings).try(&.slots)
        abort "#{cmd}: #{SLOT_NO_PROJECT}" if slots.nil?
        unless slots.activate(name)
          known = slots.names
          have = known.empty? ? "this project has no session slots saved" : "it has #{known.join(", ")}"
          abort "#{cmd}: --slot: no session slot named #{name.inspect} — #{have}. " \
                "List them with `gori run session list`"
        end
        @@active_slot = name
        # Said on STDERR, always: which identity a sweep went out as is the single fact that
        # decides how to read its results, and an overlay is invisible in the output otherwise.
        slot = slots.active
        STDERR.puts "slot: sending as #{name}#{slot.try(&.passthrough?) ? " (as captured — no header overlay)" : ""}"
      end

      # Re-select `--slot` on a freshly installed layer. Silent: the name was validated at
      # `activate_slot`, and a later open that cannot honour it (a second `--db` pointing
      # somewhere else) is not a case any command builds today — reporting it here would put
      # a line on STDERR for every internal re-open instead.
      private def self.reapply_active_slot : Nil
        return unless name = @@active_slot
        Env.layer.as?(Gori::Bindings).try(&.slots).try(&.activate(name))
      end

      # ── an overlay that shipped `$NAME` literally, said OUT LOUD ─────────────────────
      #
      # `Env.report_unbound_overlay` records every `$NAME` a slot header sent literally and
      # writes one `Log.warn`; `Env.take_unbound_overlay` is the drain its own doc reserves
      # for "a surface that prints a run summary", because a log line the operator is not
      # tailing is not a report. Nothing drained it, so the failure the mechanism was built
      # to name stayed exactly as silent as before it existed: an Authorize identity written
      # `Authorization: Bearer $SESSION` with nothing bound goes out unauthenticated, draws
      # the same 401 as anonymous, aggregates to `enforced`, and exits 0.
      #
      # ONE sentence, built here, said by every surface that ends in a summary — `gori run
      # authorize`, `gori run repeater send`, `gori run fuzz`, and MCP's `send_request` /
      # `authorize_*` through this same method. The repeated failure shape in this repo is a
      # notice fixed on one surface and left to drift on the other two.
      #
      # An INTERRUPTION and not a refusal, matching the seam it reports (`Env.unbound_in_slot`):
      # the bytes already went out, `$$NAME` is the escape for an operator who meant the
      # literal, and a guard with no exit costs more than the loss it prevents. What this owes
      # the operator is that the result is not read as evidence about an identity that was
      # never sent.
      #
      # `pairs` is `Env.take_unbound_overlay`'s output — {slot name, binding name}, in
      # first-seen order. nil when there is nothing to say, so a bound run stays silent.
      def self.unbound_overlay_note(pairs : Array({String, String})) : String?
        return nil if pairs.empty?
        # Grouped by SLOT, because the slot is the thing the operator fixes: two identities
        # each missing `$SESSION` are two configurations, not one.
        order = [] of String
        by_slot = Hash(String, Array(String)).new
        pairs.each do |(slot, name)|
          unless by_slot.has_key?(slot)
            order << slot
            by_slot[slot] = [] of String
          end
          by_slot[slot] << name unless by_slot[slot].includes?(name)
        end
        one = pairs.size == 1 && order.size == 1
        first = pairs.first[1]
        String.build do |io|
          io << "session #{one ? "value" : "values"} went out LITERALLY — "
          io << order.join("; ") { |s| "#{s} sent #{Env.token_list(by_slot[s])}" }
          io << ". Nothing bound #{one ? "it" : "them"} in this process (a binding value is "
          io << "memory-only, so every run starts with an empty table), so #{one ? "that" : "those"} "
          io << "request#{one ? "" : "s"} carried the reference itself where the session belongs "
          io << "— #{one ? "its" : "their"} response#{one ? " is" : "s are"} NOT evidence about "
          io << "the identity #{one ? "it names" : "they name"}. Bind first — replay a login under "
          io << "the slot (`--bind-from FLOW-ID` on a `gori run` sweep, a Repeater send, "
          io << "`send_request` over MCP) — or write `$$#{first}` if the literal is what you meant"
        end
      end

      # Drain and SAY it, for a `gori run` surface that has just printed its summary. Silent
      # when nothing was recorded — a run whose slot resolved is a run with no new line.
      private def self.report_unbound_slot_overlay(cmd : String) : Nil
        note = unbound_overlay_note(Env.take_unbound_overlay)
        STDERR.puts "#{cmd}: #{note}" if note
      end

      # ── session bindings, headless ───────────────────────────────────────────────────
      #
      # A session binding lives in the MEMORY of the gori that observed it and is never
      # persisted (`Bindings`: a restored token is stale by construction, and re-extracting
      # costs one request). Only `Repeater::Sender` and the proxy write the table — a sweep
      # deliberately does not, because a response echoing an attack payload back could
      # otherwise rebind the operator's session to it.
      #
      # In the TUI and over MCP that is fine: one process holds a send and the sweep that
      # follows. `gori run` is ONE-SHOT per process and had no command that sends first, so a
      # `$SESSION` in a headless fuzz/mine/sequence template could never acquire a value and
      # every request was refused — 100% of them, against every authenticated target. The
      # refusal said "nothing has extracted it yet", which reads as "wait, or retry".
      #
      # `--bind-from FLOW-ID` is the missing step, and it is deliberately a REPLAY rather than
      # persistence: it puts the deliberate send and the sweep inside one process, which is
      # exactly the shape that already works everywhere else. Persisting the value instead
      # would ship a token minutes-to-days stale into the run and produce the page of 401s the
      # feature exists to remove.

      # The {scheme, host, target} `guard_outbound` judges a `--bind-from` seed by. Named rather
      # than inlined so the decision is spec-able without a live send, the way
      # `repeater_out_of_scope?` is for `gori run repeater`. The target comes from
      # `Outbound.request_target` — the one home for reading a request-target off raw bytes,
      # which recovers it from an irregular request line instead of gating an empty path.
      private def self.bind_from_scope_parts(built : Repeater::FlowRequest::Built) : {String, String, String, Int32}
        scheme, host, port = Repeater::FlowRequest.parse_target(built.target)
        {scheme, host, Gori::Outbound.request_target(built.bytes), port}
      end

      # WHY a `--bind-from` seed replay may not go out, or nil to proceed — Layer 2, judged on
      # the SWEEP's terms rather than the Repeater's.
      #
      # The replay travels through `Repeater::Sender`, whose per-send gate is
      # `Outbound#send_block`: Sandbox ALONE, because an EXCLUDE rule deliberately does not stop
      # ONE hand-authored Repeater send — a human replaying a single request has already decided.
      # A `--bind-from` seed is not that request. It is the first send of an automated sweep,
      # issued by the sweep's own invocation, so it takes the sweep's gate — `sweep_block`, which
      # is exactly what `EXCLUDE_SWEEP_ERROR` promises when it says "excludes hold even under
      # --allow-unscoped". Without this, `--allow-unscoped` waived Layer 1 and `send_block`
      # skipped the exclude, so `discover --bind-from N --allow-unscoped` (and `fuzz`/`mine`/
      # `sequence`, which share this helper) replayed the FULL captured request — cookies and
      # Authorization included — to a host the operator had explicitly carved out.
      #
      # Named rather than inlined for the same reason `bind_from_scope_parts` is: the decision
      # is spec-able without a live send.
      #
      # `port` is the seed's OWN dial port, not the sweep's — `bind_from_scope_parts` reads it
      # off the capture's target for the same reason the host comes from there. It reaches the
      # EXCLUDE side, so a carve-out that names a port stops the seed replay too (#884).
      private def self.bind_from_seed_block(outbound : Gori::Outbound, scheme : String,
                                            host : String, target : String, port : Int32) : String?
        outbound.sweep_block(scheme, host, target, port)
      end

      # Replay flow `flow_id` through `Repeater::Sender` — the one extraction source — so its
      # response can fill the binding table before the sweep starts. Aborts on anything that
      # leaves the table unfilled: a seed that silently did nothing would hand the operator
      # back the same 100%-refused run, one flag later.
      private def self.seed_bindings(flow_id : Int64, project_name : String?, db_path : String?,
                                     outbound : Gori::Outbound, insecure : Bool, cmd : String) : Nil
        # open_store also installs the project's extract rules as `Env.layer` (see its
        # comment) — the seed depends on that having happened, which is why it reads the flow
        # through the same helper rather than opening the DB by hand.
        store = open_store(resolve_read_project(project_name, db_path), read_only: true)
        detail, overrides = begin
          {store.get_flow(flow_id), Gori::HostOverrides.load(store)}
        ensure
          store.close
        end
        abort "#{cmd}: --bind-from: no flow ##{flow_id}" unless detail
        built = Repeater::FlowRequest.build(detail)
        scheme, host, port = Repeater::FlowRequest.parse_target(built.target)
        bindings = Env.layer.as?(Gori::Bindings)
        # Split from the shared check below only so the compiler can narrow `bindings` for the
        # `values` read further down; `bind_from_blocker(nil)` returns this same sentence.
        abort "#{cmd}: #{BIND_FROM_NO_RULES}" if bindings.nil?
        if err = bind_from_blocker(bindings)
          abort "#{cmd}: #{err}"
        end
        # Layer 1, on the SEED's own host — which is not the sweep's. Each command guards its
        # `--target` with `guard_outbound` before it gets here, but `--bind-from FLOW-ID` names
        # a second, unrelated destination: whatever host that capture was taken from. Without
        # this the seed replayed a full captured request — cookies and all — to an out-of-scope
        # host that the very same invocation would have refused as a `--target`, and only
        # Sandbox (Layer 2, inside `Repeater::Sender`) could stop it. `Outbound` exists so no
        # active request leaves gori without a scope decision; a replay is an active request.
        # `--allow-unscoped` still waives it, exactly as it does for the sweep.
        # Same gap, same shape, and the same fix as #406 gave `gori run repeater`.
        gs, gh, gt, gp = bind_from_scope_parts(built)
        guard_outbound(outbound, gs, gh, gt, gp, "#{cmd}: --bind-from")
        # Layer 2, BEFORE the send rather than leaving it to `Repeater::Sender` — see
        # `bind_from_seed_block` for the exclude this closes.
        if err = bind_from_seed_block(outbound, gs, gh, gt, gp)
          outbound.close
          abort "#{cmd}: --bind-from: #{err}"
        end
        # `evidence: true` is not conditional here and cannot be: `built` is
        # `Repeater::FlowRequest.build(detail)`, which reads `request_head`/`request_body` and
        # nothing else, and the operator supplied one integer. There is no draft on this path
        # — every byte is a capture — so it is exactly the case `Sender#evidence?` describes.
        #
        # Ordering makes it look harmless and is precisely why it must be set: the binding
        # table is empty at this instant (that is what the replay is FOR), so nothing
        # substitutes today. But `Env.layer` is a per-project global that any surface may have
        # filled — and `--bind-from` is the one command whose contract is "these are somebody
        # else's bytes, sent to mint a token". A seed that spliced an already-held token into
        # the capture would corrupt the very response the run's bindings are read from.
        sender = Repeater::Sender.new(outbound, scheme: scheme, host: host, port: port,
          verify: !insecure, http2: built.http2, sni: built.sni, overrides: overrides,
          evidence: true)
        result = sender.send(built.bytes)
        if err = result.error
          abort "#{cmd}: --bind-from: replaying flow ##{flow_id} failed: #{err}"
        end
        bound = bindings.values.keys
        if bound.empty?
          abort "#{cmd}: --bind-from: " \
                "#{bind_from_nothing_bound(bindings, flow_id, result.response.try(&.status))}"
        end
        STDERR.puts "bind-from: flow ##{flow_id} replayed → bound #{Env.token_list(bound)}"
        # The seed replay ran with the table still EMPTY — that is what it is for — so the
        # active slot's own `$NAME` went out literally on this one request and
        # `Env.report_unbound_overlay` recorded it. Drained and DROPPED here: the sweep that
        # follows resolves those names, and letting the record survive would put
        # `unbound_overlay_note` on the summary of a run whose bindings are fine. Measured:
        # `--slot idA --bind-from 1` warned about the very `$SESSION` the same line above
        # reports as bound. Anything STILL unbound is re-recorded by the sweep's own sends
        # (`take_unbound_overlay` clears the log throttle with it), so nothing is swallowed.
        Env.take_unbound_overlay
      end

      # WHY a `--bind-from` replay came back with nothing bound — the sentence that decides
      # what the operator does next, and the one place it was measurably wrong.
      #
      # The default arm blames three innocent things (host glob, condition, selector) and is
      # right only when the rule was ASKED and missed. `Bindings#scoped_out` names the other
      # case: an enabled rule that MATCHED but was never asked, because a session slot claims
      # it and no slot is the send context. `gori run session edit idA --rule SESSION` silently
      # broke every existing `--bind-from` playbook that way, and `--clear-rules` silently
      # fixed it — with this sentence sending the operator to re-check a rule that was never
      # the problem, three times over.
      #
      # Both halves can be true at once (one rule scoped out, another asked and missed), so the
      # scoped-out arm names its rules and slots and leaves the generic advice attached.
      # `status` and not the whole `Repeater::Result`, so the sentence has exactly the two
      # inputs it reads and a spec can hold both.
      private def self.bind_from_nothing_bound(bindings : Gori::Bindings, flow_id : Int64,
                                               status : Int32?) : String
        replayed = "flow ##{flow_id} replayed (HTTP #{status || "?"}) but nothing was bound"
        skipped = bindings.scoped_out
        if skipped.empty?
          return "#{replayed} — no extract rule matched its response, so check the rule's " \
                 "host glob, condition and selector with `gori run rewriter extract`"
        end
        # `{rule name, the slots claiming it}` → "$SESSION (claimed by idA)".
        detail = skipped.join(", ") do |(name, slots)|
          "#{Env.token_list([name])} (claimed by #{slots.join(", ")})"
        end
        pick = skipped.first[1].first
        "#{replayed}, and #{skipped.size == 1 ? "the rule that would have bound is" : "the rules that would have bound are"} " \
        "not being asked: #{detail}. A claimed rule is only read when its slot is the send " \
        "context, and this run has no slot active — so the rule was skipped, not missed. Send " \
        "as that identity (`--slot #{pick}`), or give the rule back to the global table " \
        "(`gori run session edit #{pick} --clear-rules`)"
      end

      # Why `--bind-from` cannot bind anything in this project, or nil to go ahead. Shared by
      # `seed_bindings` (which owns the replay) and `preflight_bind_from` (which runs the same
      # test before the plan exists), so the two can never disagree about what "this project
      # has nothing to bind" means.
      #
      # The all-disabled case is called out separately: `declared` filters on `enabled?`, so a
      # project whose only extract rule is switched off used to be told it "declares no extract
      # rules" and to add one — which is both false and the wrong action.
      BIND_FROM_NO_RULES = "--bind-from: this project declares no extract rules, so a replay has " \
                           "nothing to bind — add one with `gori run rewriter extract add`"

      # The refusal for a `--bind-from` run with NO PROJECT in play, which is a different fact from
      # the sentence above and used to be told as that one.
      #
      # `Env.layer` is hydrated by `open_store`, and on the `--request`/stdin path with no
      # --project/--db nothing has opened a project by preflight time (`hydrate_project_env` is
      # skipped, the source is a file, `cli_host_overrides` returns nil without opening). So the
      # layer is nil, `bind_from_blocker(nil)` said "this project declares no extract rules", and
      # that was measurably FALSE — the ambient project may declare several — while sending the
      # operator to `rewriter extract add` to write a rule that already exists. The action they
      # actually need is to NAME the project.
      #
      # Deliberately not fixed by hydrating the ambient project here: binding a standalone run to
      # the ambient project is the product call `optional_project_outbound` defers on #354, and it
      # would also silently pull that project's Sandbox/scope into a run this surface announces as
      # UNSCOPED. One fact, one sentence; the behaviour change stays with #354.
      BIND_FROM_NO_PROJECT = "--bind-from: no project is in play (--request/stdin without " \
                             "--project/--db), so no extract rules are loaded and a replay has " \
                             "nothing to bind — name the project with --project NAME (or --db PATH)"

      private def self.bind_from_blocker(bindings : Gori::Bindings?) : String?
        return BIND_FROM_NO_RULES if bindings.nil?
        return nil unless bindings.declared.empty?
        disabled = bindings.disabled_rule_ids
        return BIND_FROM_NO_RULES if disabled.empty?
        ids = disabled.values.sort!.join(", ")
        "--bind-from: every extract rule in this project is disabled, so a replay has nothing " \
        "to bind — enable one with `gori run rewriter extract enable #{disabled.values.min}` " \
        "(disabled: ##{ids})"
      end

      # The same refusal, hoisted AHEAD of the plan build.
      #
      # `Plan.build`'s unresolved-env check runs first and fires on exactly the template
      # `--bind-from` was passed for (`Authorization: Bearer $TOKEN` with the rule switched
      # off), so the flag was discarded without a word — `seed_bindings` was never reached.
      # This needs only `Env.layer`, which the surface's `open_store` has already hydrated by
      # the time it runs, so it can move ahead of the plan without the store or the outbound.
      private def self.preflight_bind_from(bind_from : Int64?, cmd : String) : Nil
        return unless bind_from
        err = preflight_bind_from_blocker(Env.layer.as?(Gori::Bindings))
        abort "#{cmd}: #{err}" if err
      end

      # Why `--bind-from` cannot bind at PREFLIGHT time, or nil to go ahead. Split from the abort
      # for the same reason `bind_from_blocker` is: a decision reached only through `abort` is
      # untestable by construction, and every spec of it stays green if the line is deleted.
      #
      # The one difference from `bind_from_blocker` is the nil case, and it is the whole fix: a nil
      # layer HERE means no project was ever opened (`Env.layer` is hydrated by `open_store`, which
      # the `--request`/stdin path with no --project/--db never calls), not a project without rules.
      # `bind_from_blocker` keeps its own nil branch on the no-rules sentence because `seed_bindings`
      # reaches it AFTER an `open_store`, where nil is a genuine load failure instead.
      def self.preflight_bind_from_blocker(layer : Gori::Bindings?) : String?
        return BIND_FROM_NO_PROJECT if layer.nil?
        bind_from_blocker(layer)
      end

      # One sentence for every `gori run` tool whose builder refused an env token that
      # resolves to nothing (#519). Shared rather than written per command because, unlike
      # the other plan reasons, this one names no flag of the command's own — the token is
      # the whole fact and the remedy is the same everywhere. `detail` is the builder's
      # prefixed, comma-joined token list (`$SESSION, $TOKEN`).
      # `where` names the thing that carried the token (e.g. " for session #3") and belongs
      # on the FACT, not after the remedy — "...or remove the token for session #3" reads as
      # if the token were the session's.
      private def self.env_unresolved_error(detail : String?, where : String = "") : String
        hits, rest = split_disabled_rule_tokens(detail)
        return "unresolved env #{detail}#{where} — set it with `gori run project env set KEY value`, " \
               "or remove the token" if hits.empty?
        names = hits.map { |(name, id)| "#{Settings.env_prefix}#{name} (extract rule ##{id})" }.join(", ")
        enable = hits.map { |(_, id)| "`gori run rewriter extract enable #{id}`" }.join(", ")
        tail = rest.empty? ? "" : " · #{Env.token_list(rest)} is not declared by any rule — " \
                                  "set it with `gori run project env set KEY value`, or remove the token"
        "#{names}#{where} #{hits.size == 1 ? "is" : "are"} declared by an extract rule that is " \
        "DISABLED, so nothing resolves the token — re-enable with #{enable}, then bind it for " \
        "this run with --bind-from FLOW-ID. Not `gori run project env set`: that persists the " \
        "value into the project, which is what a session binding exists to avoid, and it is " \
        "stale by the next run#{tail}"
      end

      # Split a builder's refused-token list into the names a DISABLED extract rule declares
      # (with its id) and the names nothing declares at all.
      #
      # `Bindings#declared` filters on `enabled?` — deliberately, so that disabling the writer
      # cannot leave a reader injecting a stale value — which means a switched-off rule's name
      # arrives here indistinguishable from a typo. The generic remedy for that is
      # `gori run project env set`, and following it stores a live session token in the project
      # DB: precisely the outcome `bindings.cr` documents itself as preventing ("The rule
      # persists; the value never does"), and stale on the next run. So the two cases have to
      # be told apart before the sentence is chosen.
      #
      # `detail` is the builder's own `Env.token_list` output, so it is parsed back with the
      # same prefix that produced it.
      private def self.split_disabled_rule_tokens(detail : String?) : {Array({String, Int64}), Array(String)}
        hits = [] of {String, Int64}
        rest = [] of String
        return {hits, rest} unless detail
        ids = Env.layer.as?(Gori::Bindings).try(&.disabled_rule_ids)
        return {hits, rest} unless ids && !ids.empty?
        prefix = Settings.env_prefix
        detail.split(", ").each do |token|
          name = token.starts_with?(prefix) ? token[prefix.size..] : token
          if id = ids[name]?
            hits << {name, id}
          else
            rest << name
          end
        end
        {hits, rest}
      end

      # The QL `gori run history`/`ls` actually runs, plus the positional terms an explicit
      # `--query` swallowed (nil when none were).
      #
      # `--query` wins over a POSITIONAL query — but NOT over a negation term, and the difference
      # is provenance. A positional is a second spelling of the same argument, so letting the
      # explicit flag win is a choice. A `-path:/b` is not: OptionParser would have aborted it as
      # an unknown option, so `split_ql_negations` reclassified it out of argv on the operator's
      # behalf — and the old `query ||= (positional + neg_terms).join` then threw it away
      # whenever `--query` was also given. Measured with 3 flows: `history 'host:x' '-path:/b'`
      # returned the two that match, `history --query='host:x' '-path:/b'` returned all three.
      # A silently BROADER result set is the one outcome `warn_query_terms` exists to shout
      # about, and the dropped term never reached it either. Spaces are QL's AND, which the
      # positional join already assumed.
      #
      # Returned rather than aborted so the caller owns the message, and named rather than
      # inlined so the precedence is spec-able without a store or a tty.
      def self.compose_history_query(query : String?, positional : Array(String),
                                     neg_terms : Array(String)) : {String?, String?}
        if q = query
          # Parenthesize the flag value when a negation is appended. QL is
          # `NOT > AND > OR`, so `host:a OR host:b -path:/admin` is
          # `host:a OR (host:b AND NOT path:/admin)` — every `/admin` hit on host
          # `a` stays, which is the silently BROADER set this helper exists to
          # prevent. AND-only `--query` is unchanged in meaning: `(host:x) -path:/b`
          # is the same filter as `host:x -path:/b`.
          combined = if neg_terms.empty?
                       q
                     else
                       "(#{q}) #{neg_terms.join(' ')}"
                     end
          {combined, positional.empty? ? nil : positional.join(' ')}
        else
          pq = (positional + neg_terms).join(' ')
          {pq.empty? ? nil : pq, nil}
        end
      end

      # The two warnings every positional-QL surface owes its operator, beside the composer whose
      # `dropped` half feeds the first. Shared because the alternative is what it replaced: the
      # sentence copy-pasted per command (three copies, one word apart) and the SECOND warning
      # present on `history` alone.
      #
      # That second one is the whole reason this is not cosmetic. `compose_history_query`'s own
      # docstring justifies itself with "A silently BROADER result set is the one outcome
      # `warn_query_terms` exists to shout about" — but probe and sitemap only ever ran the
      # invalid-regex half, never `QL.analyze(q).ignored`, so on those two surfaces the thing it
      # exists to shout about went out silent. Measured before/after on all three:
      # `--query='path:/keep size:>bogus'` — a KNOWN field whose value will not compile, so
      # `size_cond` returns nil, `analyze` reports it ignored, the filter collapses to `path:/keep`
      # and the result is broader than asked. `QL::EMPTY` does not catch it, because `path:/keep`
      # compiles fine.
      #
      # An unknown field NAME (`hostt:x`) is NOT this case and must not be expected here: ql.cr's
      # `field_cond` else-branch deliberately free-texts the whole token so a typo "matches nothing
      # real", which means it DID compile and `analyze` rightly does not call it ignored. Negating
      # one (`-hostt:x`) therefore matches every row — a real sharp edge, but it belongs to that
      # design decision in ql.cr, not to this warning.
      def self.warn_dropped_query_terms(cmd : String, dropped : String?) : Nil
        return unless dropped
        STDERR.puts "gori run #{cmd}: --query given, so the positional query term(s) " \
                    "#{dropped.inspect} were ignored"
      end

      # Refuse a query that names a `field:`/`field~` QL does not implement, rather than running
      # it. `ql.cr`'s `field_cond` else-branch free-texts an unknown field's WHOLE token on
      # purpose — `methd:GET` becomes a literal substring search over method/host/path — so a
      # one-shot command answered `no flows match "methd:GET"`, which reads as "the project is
      # empty" and not as "you spelled `method` wrong". A scripted surface gets a SUCCESS status
      # and an empty list out of that; nothing anywhere says a field name was not a field name.
      #
      # Refusal is the DEFAULT here, and the escape hatch is spelled `--lenient` rather than the
      # opt-in being spelled `--strict`, because an opt-in leaves the silent answer as what an
      # operator who has not read this gets. It is also why this is not `warn_query_terms`: that
      # one shouts about a term QL DROPS, which broadens the result and leaves something to look
      # at. This one has nothing to look at.
      #
      # Deliberately NOT applied to the TUI filter bar (an operator types `meth` on the way to
      # `method:`, and a live filter re-evaluates every keystroke) nor to MCP, whose `strict`
      # argument already offers this and defaults false for its own compatibility reasons.
      def self.refuse_unknown_query_fields(cmd : String, q : String?, lenient : Bool) : Nil
        return if lenient
        (msg = unknown_query_field_error(cmd, q)) && abort(msg)
      end

      # The sentence `refuse_unknown_query_fields` aborts with, or nil to proceed — split out for
      # the reason `list_leftover_error` is: `abort` is not spec-able, and the DECISION is the
      # half worth pinning.
      #
      # Reports the FIRST unknown field only. A query is usually wrong in one place, and the
      # operator has to re-run either way; naming one field leaves room in the line for the
      # suggestion, which is the part that ends the round trip.
      #
      # `QL.known_field?`, NOT `QL::FIELDS.includes?`: `FIELDS` is the pool a surface OFFERS and
      # QL accepts spellings it does not offer (`res.body`, `req.size` — `QL::FIELD_ALIASES`), so
      # the narrower list would refuse a query QL compiles perfectly.
      def self.unknown_query_field_error(cmd : String, q : String?) : String?
        return nil unless q
        use = QL.fields_used(q).find { |f| !QL.known_field?(f.name) }
        return nil unless use
        # Echoed with the operator it was WRITTEN with, so `body~` does not come back as `body:`.
        bad = "#{use.name}#{use.regex ? '~' : ':'}"
        tail = "run with --lenient to search it as text instead"
        if near = QL.suggest_field(use.name)
          "gori run #{cmd}: unknown query field `#{bad}` — did you mean " \
          "`#{near}#{use.regex ? '~' : ':'}`? (#{tail})"
        else
          "gori run #{cmd}: unknown query field `#{bad}` — QL has no such field. " \
          "Fields: #{QL::FIELDS.join(' ')} (#{tail})"
        end
      end

      # The notes a `scope:` query owes an operator on a surface that prints its rows and exits.
      # Both name a state in which the query runs CLEAN and returns NOTHING, which an empty
      # listing cannot distinguish from "no traffic matched" — and the two have different fixes
      # (add scope rules; drop one of the two lenses). Returned rather than printed so the
      # wording is pinned by a spec and a second surface cannot come to word it differently;
      # the TUI's filter bar carries the same two sentences in its one-line form.
      def self.scope_query_notes(q : String, lens : QL::ScopeLens, in_scope : Bool = false) : Array(String)
        return [] of String unless QL.uses_scope?(q)
        notes = [] of String
        unless lens.configured?
          notes << "the query asks about scope, but no scope rules are configured — nothing is " \
                   "in scope, so `scope:in` and `scope:out` match nothing"
        end
        if in_scope
          # Deliberately does not name WHICH spelling goes empty: `--in-scope` narrows flows on
          # `history` and whole HOSTS on `sitemap`/`probe`, and an un-negated `scope:out` is the
          # empty one while `-scope:out` is merely redundant. State the composition, let the
          # spelling follow from it.
          notes << "--in-scope is already narrowing to what is in scope, and the query's `scope:` " \
                   "term applies on top of it (an un-negated `scope:out` is then empty)"
        end
        notes
      end

      def self.warn_query_terms(cmd : String, q : String) : Nil
        QL.invalid_regex_terms(q).each do |t|
          STDERR.puts "gori run #{cmd}: warning: invalid regex in #{t.inspect} — that term matches nothing"
        end
        # `SCOPE_SHAPE_ONLY`, not the project's real lens: this runs BEFORE the store is opened
        # at every caller (deliberately — `authorize` says out loud that hearing about a bad
        # query should not cost a project open), and the two lenses classify every `scope:` term
        # identically, so the shape-only reading is the same answer without the store. It does
        # assume the caller COMPILES with a lens — every one of them does; a surface that parses
        # without one would drop a `scope:` term and this warning would be the thing that named
        # it, so thread a lens there rather than relaxing this.
        ignored = QL.analyze(q, scope: QL::SCOPE_SHAPE_ONLY).ignored
        return if ignored.empty?
        STDERR.puts "gori run #{cmd}: warning: ignored #{ignored.map(&.inspect).join(", ")} " \
                    "— unrecognized or invalid, so the result is BROADER than the query asks for"
      end

      # QL negation terms ("-field:value" / "-field~rx") begin with '-', so OptionParser
      # aborts them as unknown options before the positional-query join ever runs. Pull
      # them out first so they join the query like any other positional term. A single-
      # letter short flag ("-n50", "-k") has no ':'/'~' after the name, so it's untouched.
      private def self.split_ql_negations(args : Array(String)) : {Array(String), Array(String)}
        neg = [] of String
        rest = [] of String
        # Classify on a scrubbed copy: argv comes from the OS unvalidated, and PCRE2 raises
        # "Regex match error: UTF-8 error" on a non-UTF-8 subject — `gori run history $'\xff'`
        # backtraced out of `main`, since neither `Run.dispatch` nor `CLI.run` rescues
        # ArgumentError. Same remedy as `read_token_list` in ./run/sequence.cr. `scrub` returns
        # self for valid UTF-8, and it is `a` (not `a.scrub`) that is kept, so the operator's
        # query bytes reach QL exactly as typed.
        # Dotted field names (`-resp.body:x`, `-req.header:Cookie`) are the documented
        # QL spelling. `[A-Za-z]+` stops at the first `.`, so those stayed in argv and
        # OptionParser aborted them as unknown options — the positional form the
        # splitter was written for, and the one the TUI bar / docs teach.
        args.each { |a| a.scrub.matches?(/\A-[A-Za-z]+(?:\.[A-Za-z]+)*[:~]/) ? (neg << a) : (rest << a) }
        {neg, rest}
      end

      # A short `-q` value that itself starts with '-' (e.g. `-q '-method:POST'`)
      # confuses OptionParser: it reads "-method:POST" as another flag rather than
      # -q's value, and the query is silently dropped. `--query=VALUE` doesn't have
      # this problem (OptionParser only splits on the first '='), so rewrite every
      # `-q`/`-qVALUE`/`-q=VALUE`/`-q VALUE` form into `--query=VALUE` up front.
      private def self.normalize_query_flag(args : Array(String)) : Array(String)
        out = [] of String
        i = 0
        while i < args.size
          a = args[i]
          if a == "-q" || a == "--query"
            if v = args[i + 1]?
              out << "--query=#{v}"; i += 2
            else
              out << a; i += 1
            end
          elsif a.starts_with?("-q=")
            out << "--query=#{a[3..]}"; i += 1
          elsif a.starts_with?("-q") && a.size > 2
            out << "--query=#{a[2..]}"; i += 1
          else
            out << a; i += 1
          end
        end
        out
      end

      # Refuse the positionals a LIST command was handed. A `list` takes none, but every
      # `rewriter`/`probe rules` dispatcher routes a first token starting with '-' straight to
      # its list command on the assumption that the rest are list options — so a global flag
      # written BEFORE the verb (`rewriter --project=t1 rm 1`, the ordering every other
      # `gori run` command accepts) discarded the verb AND its id, listed the rules, and exited
      # 0. A destructive mutation that silently no-ops with a SUCCESS status is the failure this
      # file's own header (see the `verb_token?` guards) calls the worst one a scripted surface
      # can have, so it becomes a usage error that names the ordering.
      private def self.refuse_list_leftovers(leftover : Array(String), sub : String,
                                             verbs : String, read_verb : String = "list") : Nil
        (msg = list_leftover_error(leftover, sub, verbs, read_verb)) && abort(msg)
      end

      # The sentence `refuse_list_leftovers` aborts with, or nil to proceed. Split out so the
      # decision AND the message are spec-able — `abort` is not — and now the single seam for
      # twelve call sites, which is what makes `read_verb` belong here rather than in each of them.
      # One DELIBERATE exclusion: `cmd_probe_scan` takes a positional QL query (`gori run probe
      # [QL query]`), so a leftover there is the operator's filter, not a discarded verb. Do not
      # add this to it.
      #
      # `read_verb` is the command's OWN read verb, and a lone one is NOT refused. The guard exists
      # for "a destructive mutation that silently no-ops with a SUCCESS status" (see
      # refuse_list_leftovers above); the read verb is neither destructive nor a no-op — it is
      # precisely what this command was about to do anyway. Without this, the leading-flag route
      # turned every `<cmd> --project=X list` into a usage error, because that route hands the list
      # command its own name as a leftover (`cmd_issues` → `verb_token?("--project=X")` is false →
      # `cmd_issues_list(["--project=X", "list"])`, leftover `["list"]`). The message was
      # self-refuting too: it called `list` an unknown subcommand while listing `list` among the
      # verbs. `gori run project sandbox` passes "status" — the only one of the twelve whose read
      # verb is not spelled `list`.
      #
      # Exactly one token, and exactly that word: `issues --project=X list rm 3` still names `list`
      # as the discarded-verb position, because there a real second verb followed it.
      def self.list_leftover_error(leftover : Array(String), sub : String, verbs : String,
                                   read_verb : String = "list") : String?
        return nil if leftover.empty?
        return nil if leftover.size == 1 && leftover[0] == read_verb
        "gori run #{sub}: unknown subcommand '#{leftover[0]}' — global flags go AFTER " \
        "the subcommand (`gori run #{sub} #{leftover[0]} … --project=NAME`). Verbs: #{verbs}"
      end

      # History / probe / sitemap take a positional QL, so `refuse_list_leftovers` cannot sit
      # on their list/scan command — `history host:x` is the operator's filter. A leftover
      # that IS a reserved verb is still the flag-before-verb discard: `history --project=X
      # delete 42` listed instead of deleting, `probe --project=X dismiss 5` scanned with
      # the free-text `dismiss 5`. Same sentence as `list_leftover_error`.
      def self.reserved_query_verb_error(leftover : Array(String), sub : String,
                                         reserved : Array(String), verbs : String) : String?
        first = leftover.first?
        return nil unless first && reserved.includes?(first)
        list_leftover_error(leftover, sub, verbs)
      end

      private def self.take_flow_id(rest : Array(String), sub : String) : Int64
        abort "gori run #{sub}: missing <flow-id>" if rest.empty?
        abort "gori run #{sub}: too many arguments (expected one <flow-id>, got: #{rest.join(" ")})" if rest.size > 1
        parse_flow_id(rest[0], "gori run #{sub}")
      end

      private def self.parse_flow_id(v : String, cmd : String = "gori run") : Int64
        v.to_i64? || abort "#{cmd}: invalid flow id '#{v}'"
      end

      private def self.parse_port(v : String) : Int32
        n = v.to_i?
        abort "gori run: invalid --port '#{v}' (expected 0-65535)" unless n && 0 <= n <= 65535
        n
      end

      private def self.parse_count(v : String, flag : String? = nil) : Int32
        n = v.to_i?
        abort "gori run: invalid #{flag || "count"} '#{v}' (expected a positive integer)" unless n && n > 0
        n
      end

      # "30s" / "5m" / "1h" / bare seconds → a Time::Span.
      private def self.parse_duration(v : String) : Time::Span
        # .scrub for the same reason as `split_ql_negations` above: `--for $'\xff'` is a
        # PCRE2 UTF-8 error, not a match failure, and it escaped to `main`. A scrubbed byte
        # is U+FFFD, which no digit class accepts, so junk still lands on the abort below —
        # which keeps printing the raw `v` the operator typed.
        m = v.scrub.match(/\A(\d+)(s|m|h)?\z/)
        abort "gori run: invalid duration '#{v}' (use e.g. 30s, 5m, 1h)" unless m
        # .to_i? (not .to_i): the regex permits arbitrarily many digits, so a value
        # like 99999999999999999999 would overflow Int32 and crash with an unhandled
        # ArgumentError. Treat an out-of-range duration as a clean usage error.
        n = m[1].to_i? || abort("gori run: --for '#{v}' is out of range")
        abort "gori run: --for must be greater than 0 (got '#{v}')" if n == 0
        # `n.hours` / `n.minutes` build a Span in nanoseconds. An Int32-fitting value
        # like 2562048h still overflows Int64 and wraps to a tiny/negative sleep.
        unit_ns = case m[2]?
                  when "m" then 60_000_000_000_i64
                  when "h" then 3_600_000_000_000_i64
                  else          1_000_000_000_i64
                  end
        abort "gori run: --for '#{v}' is out of range" if n.to_i64 > Int64::MAX // unit_ns
        case m[2]?
        when "m" then n.minutes
        when "h" then n.hours
        else          n.seconds
        end
      end

      private def self.parse_format(v : String, allowed : Array(Symbol)) : Symbol
        sym = case v.downcase
              when "text"           then :text
              when "json"           then :json
              when "jsonl"          then :jsonl
              when "raw"            then :raw
              when "har"            then :har
              when "curl"           then :curl
              when "python"         then :python
              when "fetch"          then :fetch
              when "go"             then :go
              when "httpie"         then :httpie
              when "csrf"           then :csrf
              when "paths"          then :paths
              when "markdown", "md" then :markdown
              when "sarif"          then :sarif
              else                       abort "gori run: unknown --format '#{v}'"
              end
        abort "gori run: --format #{v} not valid here (use #{allowed.join("|")})" unless allowed.includes?(sym)
        sym
      end

      private def self.display_body(head : Bytes?, body : Bytes?) : Bytes?
        decode_body(head, body)[0]
      end

      # Decode a Content-Encoding/Transfer-Encoding body for display, returning the
      # bytes plus whether any decoding actually happened. When `true`, the bytes no
      # longer match the message's Content-Encoding/Content-Length headers — the JSON
      # output surfaces this as `body_decoded` so scripts aren't misled. (`--format
      # raw` still emits the exact wire bytes.)
      private def self.decode_body(head : Bytes?, body : Bytes?) : {Bytes?, Bool}
        decoded, _ = Proxy::Codec::ContentDecode.decode(head, body)
        decoded ? {decoded, true} : {body, false}
      end

      private def self.scrub(bytes : Bytes?) : String?
        bytes ? String.new(bytes).scrub : nil
      end

      # The CLI counterpart of MCP's Serialize.emit_body (src/gori/mcp/serialize.cr)
      # — same object shape ({encoding, size, truncated, text|base64, binary?,
      # wire_truncated?, note?}) so a script gets a consistent contract whether it
      # reads `gori mcp` or `gori run … --format json`. UNCLIPPED: unlike MCP (which
      # caps at MAX_TEXT/MAX_B64 for an LLM's context window), the CLI is read by a
      # script that expects the whole value, so no size cap is applied here.
      private def self.emit_body_json(j : JSON::Builder, field_name : String, head : Bytes?, body : Bytes?, wire_truncated : Bool) : Nil
        if body.nil? || body.empty?
          j.field field_name, nil
          return
        end
        decoded, note, complete = Proxy::Codec::ContentDecode.decode_full(head, body)
        bytes = decoded || body
        s = String.new(bytes)
        j.field field_name do
          j.object do
            if s.valid_encoding?
              j.field "encoding", "text"
              j.field "size", bytes.size
              j.field "truncated", wire_truncated
              j.field "text", s
            else
              j.field "encoding", "base64"
              j.field "binary", true
              j.field "size", bytes.size
              j.field "truncated", wire_truncated
              j.field "base64", Base64.strict_encode(bytes)
            end
            j.field "wire_truncated", true if wire_truncated
            j.field "note", note if note
            # A coding that stopped mid-stream. Distinct from `truncated`/`wire_truncated`,
            # which are about the CAPTURE cap: this one says the decoder never reached the
            # end of the encoded stream, so the text/base64 above is a prefix of what the
            # origin meant to send. Silence here read as "decoded: gzip, all of it".
            j.field "decode_truncated", true unless complete
            emit_trailers_json(j, head, body)
          end
        end
      end

      # The chunked message's TRAILER fields (RFC 7230 §4.1.2), beside the de-chunked body.
      # `ContentDecode.dechunk` stops at the terminating 0-chunk and the rendered `head`
      # stops at the blank line before the body, so a trailer was captured by NEITHER half
      # while the origin's `Trailer:` announcement was still echoed in the head — the one
      # reading an operator can draw from that is "the origin sent none". `repeater send`
      # persists no flow, so on that path there was no `show --format raw` to fall back to.
      # Same field name and shape as MCP's `Serialize.emit_trailers`.
      private def self.emit_trailers_json(j : JSON::Builder, head : Bytes?, body : Bytes?) : Nil
        trailers = Proxy::Codec::ContentDecode.trailers(head, body)
        return if trailers.empty?
        j.field "trailers" do
          j.array do
            trailers.each do |(name, value)|
              j.object do
                j.field "name", name.scrub
                j.field "value", value.scrub
                # A trailer value is remote bytes; `scrub` above is lossy, so hand back the
                # exact octets whenever it changed them (mirrors the binary-body fallback).
                unless value.valid_encoding?
                  j.field "value_base64", Base64.strict_encode(value.to_slice)
                  j.field "value_lossy", true
                end
              end
            end
          end
        end
      end

      # `body` is the DECODED body (de-chunked/inflated) that the operator reads; `wire_body`
      # is the stored wire form the trailers still live in, and is optional only because a
      # caller with no chunked wire form has nothing to pass.
      private def self.print_message_text(head : Bytes?, body : Bytes?, wire_body : Bytes? = nil) : Nil
        # Neutralize ANSI/OSC/CSI escapes in captured (attacker-controlled) head/body
        # before writing to the live terminal; `binary_body?` only sniffs for NUL, so an
        # escape-only payload would otherwise pass through. `--format raw` stays exact.
        STDOUT.puts(CLI::Output.term_safe_multiline(String.new(head || Bytes.empty).scrub).rstrip)
        if body && !body.empty?
          STDOUT.puts ""
          if binary_body?(body)
            STDOUT.puts "[binary body, #{body.size} bytes — use --format raw for exact bytes, or view hex]"
          else
            STDOUT.puts(CLI::Output.term_safe_multiline(String.new(body).scrub))
          end
        end
        print_decode_note(head, wire_body)
        print_trailers_text(head, wire_body)
      end

      # Name the derivation under a body that IS one. The text view prints a de-gzipped,
      # de-chunked body under a head that still says `Content-Encoding: gzip` /
      # `Transfer-Encoding: chunked` / a Content-Length that no longer matches, and said
      # nothing about it — while `--format json` and MCP both emit the same fact as `note`.
      # A truncated stream is the case that matters most: the note is where "(stream
      # truncated)" lands, so text and JSON now agree that the decode did not finish.
      private def self.print_decode_note(head : Bytes?, wire_body : Bytes?) : Nil
        return if wire_body.nil? || wire_body.empty?
        _, note = Proxy::Codec::ContentDecode.decode(head, wire_body)
        return unless note
        STDOUT.puts ""
        STDOUT.puts "[note] #{CLI::Output.term_safe(note)}"
      end

      # Trailers under their own heading, after the body. The decoded text view drops
      # everything past the terminating 0-chunk, so a trailer the origin really sent showed
      # up in neither the head nor the body — see emit_trailers_json. Labelled, never merged
      # into the head: whether the far side treats a trailer as a header is the test.
      private def self.print_trailers_text(head : Bytes?, wire_body : Bytes?) : Nil
        trailers = Proxy::Codec::ContentDecode.trailers(head, wire_body)
        return if trailers.empty?
        STDOUT.puts ""
        STDOUT.puts "--- trailers ---"
        trailers.each do |(name, value)|
          STDOUT.puts(CLI::Output.term_safe_multiline("#{name}: #{value}".scrub))
        end
      end

      # `.scrub` only fixes invalid UTF-8 byte sequences — it does NOT strip control
      # bytes, so a binary body (e.g. a PNG/NUL-laden blob) would otherwise dump raw
      # control bytes (NUL/SUB/ESC/…) straight to the terminal and corrupt it. Sniff
      # for a NUL in the first 8KB, mirroring the TUI's binary-body guard.
      private def self.binary_body?(bytes : Bytes) : Bool
        n = {bytes.size, 8192}.min
        n.times { |i| return true if bytes[i] == 0u8 }
        false
      end

      # head lines + blank + body lines (scrubbed), for the --diff line comparison.
      private def self.message_lines(head : Bytes?, body : Bytes?) : Array(String)
        lines = bytes_to_lines(head)
        # The head BLOB ends with the CRLF CRLF that terminates the header block,
        # so splitting it leaves trailing empty lines; drop them and add exactly one
        # blank separator before the body (matches the non-diff text view).
        while !lines.empty? && lines.last.empty?
          lines.pop
        end
        if body && !body.empty?
          lines << ""
          lines.concat(bytes_to_lines(body))
        end
        lines
      end

      private def self.bytes_to_lines(bytes : Bytes?) : Array(String)
        return [] of String unless bytes
        String.new(bytes).scrub.split('\n').map(&.rstrip('\r'))
      end

      private def self.print_diff(diff : Array(Repeater::DiffLine)) : Nil
        diff.each { |dl| puts "#{diff_prefix(dl)}#{dl.text}" }
      end

      # A FOLDED diff (`--context`): the collapsed runs print as their own `@@ … @@` row, in
      # place, so the marker sits where the hidden lines were rather than being appended as a
      # summary the reader has to re-position by hand.
      private def self.print_folded_diff(diff : Array(Repeater::Diff::Folded)) : Nil
        diff.each do |f|
          if line = f.line
            puts "#{diff_prefix(line)}#{line.text}"
          else
            puts "@@ #{f.hidden} unchanged lines @@"
          end
        end
      end

      private def self.diff_prefix(dl : Repeater::DiffLine) : String
        case dl.kind
        in Repeater::DiffKind::Same then " "
        in Repeater::DiffKind::Add  then "+"
        in Repeater::DiffKind::Del  then "-"
        end
      end
    end
  end
end
