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
require "../discover"
require "../discover/adapters"
require "../oast/provider_config"
require "../probe/passive"
require "../probe/group"
require "../notes"
require "../issues_export"
require "../links"
require "../import"
require "./output"
require "./run/interrupt"
require "./run/capture"
require "./run/history"
require "./run/repeater"
require "./run/repeater_minimize"
require "./run/compare"
require "./run/intercept"
require "./run/fuzz_args"
require "./run/fuzz"
require "./run/mine"
require "./run/sequence"
require "./run/discover"
require "./run/oast"
require "./run/probe"
require "./run/notes"
require "./run/sitemap"
require "./run/import"
require "./run/issues"
require "./run/links"
require "./run/jwt"
require "./run/cookie"
require "./run/decoder"
require "./run/rewriter"
require "./run/colormarker"
require "./run/project"

module Gori
  module CLI
    # `gori run <subcommand>` — the non-interactive CLI. Scripts the same project
    # data the TUI works on, built directly on the Store / Repeater / Session APIs
    # (NOT the verb system, whose ExecContext is ~60 UI-action methods that only
    # make sense in front of a terminal). Read subcommands open the store directly
    # and never take the capture lock, so they're safe to run alongside a live
    # capturing instance (SQLite WAL).
    module Run
      def self.dispatch(args : Array(String)) : Nil
        dispatch_subcommand(args)
      rescue ex : IO::Error
        # `gori run … | head` (or any reader that closes early) breaks the STDOUT
        # pipe; a well-behaved Unix filter exits quietly on EPIPE rather than
        # dumping an IO::Error backtrace. Re-raise anything that isn't a broken pipe.
        # (Kept as a thin wrapper so the subcommand `case` stays under the
        # cyclomatic-complexity bar — see dispatch_subcommand.)
        raise ex unless ex.os_error == Errno::EPIPE
        exit 0
      end

      private def self.dispatch_subcommand(args : Array(String)) : Nil
        Settings.load # global env vars (and other persisted defaults) for all subcommands
        # No args / -h / --help all print help. `args[1..]` is only reached in the named
        # branches, where args[0] matched a subcommand string (so args is non-empty and the
        # tail slice is safe). Folding the empty case into this `when` keeps the dispatch
        # under the cyclomatic-complexity bar; the rest of the subcommands live in
        # dispatch_subcommand2 for the same reason (one `case` would overflow the bar).
        case sub = args.first?
        when nil, "-h", "--help" then print_help
        when "capture"           then cmd_capture(args[1..])
        when "history", "ls"     then cmd_history(args[1..])
        when "show"              then cmd_show(args[1..])
        when "repeater"          then cmd_repeater(args[1..])
        when "fuzz"              then cmd_fuzz(args[1..])
        when "mine"              then cmd_mine(args[1..])
        when "sequence", "seq"   then cmd_sequence(args[1..])
        else                          dispatch_subcommand2(sub, args[1..])
        end
      end

      # The second half of the subcommand `case` (split from dispatch_subcommand so each
      # method stays under the cyclomatic-complexity bar). `sub` is non-nil here — the
      # empty/-h/--help case is handled above.
      private def self.dispatch_subcommand2(sub : String?, rest : Array(String)) : Nil
        case sub
        when "probe"       then cmd_probe(rest)
        when "discover"    then cmd_discover(rest)
        when "oast"        then cmd_oast(rest)
        when "sitemap"     then cmd_sitemap(rest)
        when "import"      then cmd_import(rest)
        when "notes"       then cmd_notes(rest)
        when "issues"      then cmd_issues(rest)
        when "jwt"         then cmd_jwt(rest)
        when "cookie"      then cmd_cookie(rest)
        when "decoder"     then cmd_decoder(rest)
        when "rewriter"    then cmd_rewriter(rest)
        when "colormarker" then cmd_colormarker(rest)
        when "project"     then cmd_project(rest)
        else                    dispatch_subcommand3(sub, rest)
        end
      end

      # The third slice of the subcommand `case` (same complexity-bar reason as
      # dispatch_subcommand2). `sub` is still non-nil here.
      private def self.dispatch_subcommand3(sub : String?, rest : Array(String)) : Nil
        case sub
        when "compare"   then cmd_compare(rest)
        when "intercept" then cmd_intercept(rest)
        when "links"     then cmd_links(rest)
        else
          STDERR.puts "gori run: unknown subcommand '#{sub}'"
          print_help
          exit 1
        end
      end

      # Left column width for `gori run -h` subcommand names (longest: "project host-override").
      SUBCMD_COL_W = 22

      SUBCOMMANDS = [
        {"capture", "Start the proxy and stream captured flows to STDOUT"},
        {"history (ls)", "List / QL-query captured flows"},
        {"history delete", "Hard-delete one captured flow by id"},
        {"history clear", "Delete ALL captured flows in the project (needs --yes)"},
        {"show <id>", "Print a flow's request/response (text, json, or raw bytes)"},
        {"repeater", "Re-send a captured flow; list/create/send (replay, incl. WebSocket) repeater sessions"},
        {"repeater minimize", "Strip noise from a saved request, keeping the response the same"},
        {"compare <a> <b>", "Diff two flows' request or response (unified diff)"},
        {"intercept", "Inspect/drive a live TUI's paused intercept queue (list, forward, drop, edit, …)"},
        {"fuzz [<id>]", "Fuzz/intrude a request: mark §…§ positions, sweep payloads"},
        {"mine [<id>]", "Discover hidden parameters (query/form/multipart/json/header/cookie)"},
        {"sequence (seq)", "Analyze token randomness (collect via replay, or --tokens FILE)"},
        {"discover", "Spider + directory brute-force a target; findings feed the Sitemap"},
        {"oast", "Listen for out-of-band callbacks (interactsh & friends); print payload + hits"},
        {"oast providers", "Manage saved OAST providers (list, add, update, enable/disable, delete)"},
        {"sitemap", "Print the host → path endpoint tree (text, json, paths)"},
        {"sitemap tag", "Pin/clear/list a free-text memo on a sitemap path"},
        {"import", "Import flows from a HAR, URL list, or OpenAPI spec into History"},
        {"probe [QL]", "Passively scan captured flows for issues (zero requests)"},
        {"probe issues", "List persisted probe findings (the TUI Probe tab's list)"},
        {"probe dismiss", "Mute a finding by id, or bulk by --code / --host"},
        {"probe promote", "Promote a finding to a human-confirmed Issue"},
        {"probe delete", "Hard-delete a finding (or --all)"},
        {"probe rules", "List/enable/disable scan rules; add or delete custom ones"},
        {"probe mode", "Get/set the scan mode (off, passive, active, aggressive)"},
        {"notes [<n>]", "Read or write the project's notes (list, <n>, --all, create, delete)"},
        {"issues", "List, export, create, update, or delete issues (text, json, markdown)"},
        {"links", "List/add/delete an issue's or note's evidence links"},
        {"jwt [<token>]", "Decode, re-sign, or generate testing payloads for a JWT"},
        {"cookie [<cookie>]", "Decode, verify, brute-force, or forge a Flask/Rack/Django session cookie"},
        {"decoder <chain>", "Encode/decode/hash via the Decoder engine (base64, hex, url, gzip …)"},
        {"rewriter", "Manage Match & Replace rules (list, add, rm, enable/disable, preview, extract, bindings)"},
        {"colormarker", "Manage History row-colour rules (list, add, rm, enable/disable, move, preview)"},
        {"project [list]", "List known projects"},
        {"project create", "Create (or reopen) a project by name"},
        {"project delete", "Delete a project and everything captured in it"},
        {"project scope", "Manage scope rules (list, add, update, delete, enable/disable)"},
        {"project sandbox", "Get/set the hard-containment sandbox gate (status, on, off)"},
        {"project env", "Manage project env vars ($KEY substitution)"},
        {"project host-override", "Manage host overrides (list, add, update, delete)"},
      ]

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

      # --db wins → else --project resolved via ProjectRegistry#find (exact short id
      # → exact dir slug → exact display name → unique id-prefix, all
      # case-insensitive) → else the most-recently-active project. Aborts when
      # nothing resolves. Routing through #find is what lets a read command finally
      # select by slug/id, not display name alone (parity with MCP --project).
      private def self.resolve_read_project(project_name : String?, db_path : String?) : Project
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
        projects = registry.list
        abort "gori run: no projects yet — capture some traffic first, or pass --db PATH" if projects.empty?
        projects.first
      end

      # Capture creates-or-reopens its target (unlike reads, which require an
      # existing one). --db targets an explicit database file instead of a project.
      private def self.resolve_capture_project(project_name : String?, db_path : String?) : Project
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

      # Opening a non-SQLite file (or a path we can't read) raises deep in the driver;
      # turn that into a clean CLI error instead of an unhandled backtrace.
      private def self.open_store(project : Project) : Store
        store = Store.open(project.db_path, retention_flows: Settings.retention_flows)
        # The project's pinned upstream / dial timeouts / capture cap (#538). `bind: false`:
        # not one command routed through here LISTENS — `gori run capture` is the only
        # subcommand that binds and it opens its project through `Session.open` instead — so
        # the two bind keys are deliberately left out and the other four apply. Without this,
        # a project pinned to a jump host was dialled DIRECT by every `gori run` active
        # command, and an imported/replayed body was capped at the global limit.
        Settings.load_project_network(store, bind: false)
        Env.load_project(store)
        # The project's extract rules become `Env`'s send-time layer here too (#501) — with
        # NO values, because a binding lives in the memory of the gori that observed it and
        # nothing writes one to disk. That is not a gap to paper over: it is what makes a
        # headless send refuse with "unbound session binding $SESSION" instead of the much
        # less useful "unresolved env $SESSION" that an undeclared name would earn. One
        # syntax, one rule, and a refusal that names its gate on every surface.
        Env.layer = Bindings.load(store)
        store
      rescue ex : DB::Error | SQLite3::Exception
        abort "gori run: cannot open database #{project.db_path}: #{ex.message.presence || "not a valid SQLite database (or unreadable)"}"
      end

      # Project host overrides for a CLI direct-dial command (fuzz/mine/sequence), loaded when
      # a project is in play — a flow-id reads from one, or --project/--db names one. Returns
      # nil for --request/stdin with no project (nothing to load; global Settings overrides
      # still apply inside Upstream.dial). Snapshots into memory, so the store can close.
      private def self.cli_host_overrides(project_name : String?, db_path : String?, flow_id : Int64?) : Gori::HostOverrides?
        return nil unless flow_id || project_name || db_path
        store = open_store(resolve_read_project(project_name, db_path))
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
                                                 allow_unscoped : Bool) : Gori::Outbound
        # ONLY fuzz/mine/sequence can genuinely run project-less (--request/stdin). Every
        # other caller reads its subject (a repeater session, a flow) out of a project and
        # must use project_outbound, or an omitted --project would silently drop the gate.
        return project_outbound(project_name, db_path, allow_unscoped) if flow_id || project_name || db_path
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
        store = open_store(resolve_read_project(project_name, db_path))
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
                                      target : String, cmd : String) : Nil
        verdict = outbound.check_request(scheme, host, target)
        return unless verdict.blocked?
        outbound.close
        abort "#{cmd}: #{host} is out of the project scope — #{Gori::Outbound.remedy(verdict, "--allow-unscoped")}"
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
      private def self.bind_from_scope_triple(built : Repeater::FlowRequest::Built) : {String, String, String}
        scheme, host, _port = Repeater::FlowRequest.parse_target(built.target)
        {scheme, host, Gori::Outbound.request_target(built.bytes)}
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
        store = open_store(resolve_read_project(project_name, db_path))
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
        # Sandbox/excludes (Layer 2, inside `Repeater::Sender`) could stop it. `Outbound` exists
        # so no active request leaves gori without a scope decision; a replay is an active
        # request. `--allow-unscoped` still waives it, exactly as it does for the sweep.
        # Same gap, same shape, and the same fix as #406 gave `gori run repeater`.
        gs, gh, gt = bind_from_scope_triple(built)
        guard_outbound(outbound, gs, gh, gt, "#{cmd}: --bind-from")
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
          abort "#{cmd}: --bind-from: flow ##{flow_id} replayed (HTTP #{result.response.try(&.status) || "?"}) " \
                "but no extract rule matched its response, so nothing was bound — check the rule's " \
                "host glob, condition and selector with `gori run rewriter extract`"
        end
        STDERR.puts "bind-from: flow ##{flow_id} replayed → bound #{Env.token_list(bound)}"
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
          combined = neg_terms.empty? ? q : ([q] + neg_terms).join(' ')
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

      def self.warn_query_terms(cmd : String, q : String) : Nil
        QL.invalid_regex_terms(q).each do |t|
          STDERR.puts "gori run #{cmd}: warning: invalid regex in #{t.inspect} — that term matches nothing"
        end
        ignored = QL.analyze(q).ignored
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
        args.each { |a| a.scrub.matches?(/\A-[A-Za-z]+[:~]/) ? (neg << a) : (rest << a) }
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
              when "paths"          then :paths
              when "markdown", "md" then :markdown
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
