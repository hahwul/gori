# `gori mcp` — the Model Context Protocol server over stdio, plus the `--install`
# helper that writes the server entry into an agent's config. Reopens Gori::CLI; the
# argv dispatch that reaches these lives in cli.cr.
module Gori::CLI
  # `gori mcp` starts a Model Context Protocol server over stdio (JSON-RPC 2.0):
  # an AI client (Claude Desktop / Claude Code) spawns it and queries gori's
  # captured data + drives repeaters. STDOUT is the protocol channel, so EVERYTHING
  # else (logs, the resolved-db banner, errors) goes to STDERR.

  private def self.run_mcp(args : Array(String)) : Nil
    db_path = nil.as(String?)
    project = nil.as(String?)
    insecure_upstream = false
    read_only = false
    tools_spec = nil.as(String?)
    use_active_project = false
    no_project = false
    # A LIST, not a single slot: `gori mcp --install-claude-code --install-codex` is what
    # someone who runs two agents types, and the last-one-wins slot this used to be
    # configured Codex alone and said nothing about the client it skipped — the same
    # "accepted, then quietly discarded" failure MCP::Install.build_args documents for the
    # selector flags, spent on a whole client instead of one flag.
    install_targets = [] of String

    parser = OptionParser.new do |p|
      p.banner = "Usage: gori mcp [options]\n\n" \
                 "Start an MCP (Model Context Protocol) server over stdio. An AI client\n" \
                 "spawns this and talks JSON-RPC on stdin/stdout. With no --db/--project,\n" \
                 "a Git workspace is path-bound to its own project. Outside a workspace\n" \
                 "the server starts unbound so the agent can list/create/switch projects.\n" \
                 "Pass --use-active-project to serve the active TUI/MRU project instead."
      p.on("--db=PATH", "Serve this SQLite db (overrides --project)") { |v| db_path = v }
      p.on("--project=NAME", "Serve a named project's db") { |v| project = v }
      p.on("--use-active-project", "Ignore the current Git workspace and serve the active TUI/MRU project") { use_active_project = true }
      p.on("--no-project", "Start unbound even inside a Git workspace (agent picks via list/create/switch)") { no_project = true }
      p.on("--insecure-upstream", "send_request: skip upstream TLS verification") { insecure_upstream = true }
      p.on("--read-only", "Disable action tools (send_request, create/update_issue); serve the project without a writer") { read_only = true }
      # No size in this text: it is compiled in, and every number written here has drifted
      # (#1137). The startup log weighs the catalogue it is about to serve instead.
      p.on("--tools=SPEC", "Advertise only these tools — comma-separated names, globs or @profiles, " \
                           "'-' subtracts (e.g. '@recon', '@minimal,send_request', '-fuzz_*,-mine_*').\n" \
                           "The client loads every advertised tool into the model's context; the\n" \
                           "startup log says how much. Profiles:\n" +
                           MCP::ToolFilter::PROFILES.join("\n") { |pr| "  @#{pr.name.ljust(9)}#{pr.summary}" }) { |v| tools_spec = v }
      p.on("--install-agy", "Install gori as an MCP server in Antigravity (~/.gemini/antigravity-cli/mcp_config.json)") { install_targets << "agy" }
      p.on("--install-codex", "Install gori as an MCP server in Codex (~/.codex/config.toml)") { install_targets << "codex" }
      p.on("--install-claude", "Install gori as an MCP server in Claude Desktop config") { install_targets << "claude" }
      p.on("--install-claude-code", "Install gori as an MCP server in Claude Code (~/.claude.json)") { install_targets << "claude-code" }
      p.on("--install-grok", "Install gori as an MCP server in Grok (~/.grok/config.toml)") { install_targets << "grok" }
      p.on("--install-hermes", "Install gori as an MCP server in Hermes ($HERMES_HOME, default ~/.hermes/config.yaml)") { install_targets << "hermes" }
      p.on("--install-pi", "Install gori as an MCP server in Pi ($PI_CODING_AGENT_DIR, default ~/.pi/agent/mcp.json; requires an MCP adapter)") { install_targets << "pi" }
      p.on("-h", "--help", "Show this help") { puts p; exit 0 }
      p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
      p.missing_option { |flag| abort "missing value for #{flag}" }
    end
    parser.parse(args)

    if use_active_project && (db_path.try(&.presence) || project.try(&.presence))
      abort "gori mcp: --use-active-project cannot be combined with --db/--project"
    end
    if no_project && (db_path.try(&.presence) || project.try(&.presence) || use_active_project)
      abort "gori mcp: --no-project cannot be combined with --db/--project/--use-active-project"
    end

    # Parsed BEFORE anything opens a store or writes a config: a misspelled pattern must
    # abort while the operator is still looking at the terminal. Left silent it produces a
    # server advertising a handful of tools, which an agent cannot tell from a gori that
    # simply does not have the feature.
    tool_filter = nil.as(MCP::ToolFilter?)
    if spec = tools_spec.try(&.strip).presence
      # Resolved against the WHOLE catalogue, never against the read-only subset. The two
      # flags describe different things — `--tools` names tools, `--read-only` withholds
      # them — and folding the gate into the name table made every action tool read as a
      # MISSPELLING: `--read-only --tools='list_*,get_*,send_request'`, the example in this
      # command's own `--tools` help, aborted with `"send_request" matches no tool`, which
      # sent the operator hunting for a typo in a name they had spelled correctly. The gate
      # is applied after the spec resolves, exactly where it is applied everywhere else
      # (`Tools#list`).
      case parsed = MCP::ToolFilter.parse(spec, MCP::Tools::TOOL_NAMES)
      in String          then abort parsed
      in MCP::ToolFilter then tool_filter = parsed
      end
    end
    # …and the "you would advertise nothing" refusal the filter makes on its own, for the
    # one way the gate can still empty the set: a spec that names only action tools on a
    # read-only server. Said with the reason, because the names in it are all real.
    advertised = MCP::Tools.served_names(tool_filter, !read_only)
    if tool_filter && advertised.empty?
      abort "gori mcp: --tools=#{tools_spec} selects only tools that --read-only disables, " \
            "so the server would advertise nothing. Name a read tool, or drop --read-only."
    end

    unless install_targets.empty?
      # Settings.path_override is `--config`, already stripped from argv by CLI.run before
      # dispatch — so run_mcp never sees the flag and can only read it back from here.
      ok = install_mcp_config(install_targets, db_path, project, read_only, insecure_upstream,
        use_active_project, no_project, Settings.path_override, tools_spec)
      exit(ok ? 0 : 1)
    end

    # Logs to STDERR ONLY — STDOUT is reserved for the JSON-RPC stream.
    Log.setup(:info, Log::IOBackend.new(STDERR))
    Settings.load # send_request's repeater engines read the upstream-proxy setting from here

    # The catalogue is the first thing this server spends, and it spends it on the operator's
    # behalf before a question is asked: an MCP client loads every tool description into the
    # model's context and keeps it there for the session. Said on EVERY start — which is why
    # it is HERE and not beside the bound server below: an unbound start (outside a git
    # workspace, `--no-project`, or a database that would not open) spends exactly the same
    # context and used to say nothing at all. The count is what this process will actually
    # advertise, gate included; "all 179 tools (--read-only)" overstated a 62-tool catalogue
    # by threefold, on the one line whose whole job is that number.
    #
    # And the WEIGHT is measured here, from the very listing the client will be handed,
    # rather than written into help or docs: every size gori ever wrote down had drifted by
    # the time #1137 measured it. One JSON build of a few hundred KB, once per start.
    weight = "tools/list ~#{(MCP::Tools.catalogue_json(tool_filter, !read_only).bytesize / 1024.0).round.to_i} KB"
    if f = tool_filter
      Log.info { "mcp: --tools=#{f.spec} advertises #{advertised.size} of #{MCP::Tools::TOOL_NAMES.size} tools (#{weight}): #{advertised.sort.join(", ")}" }
    else
      Log.info do
        served = advertised.size == MCP::Tools::TOOL_NAMES.size ? "all #{advertised.size}" : "#{advertised.size} of #{MCP::Tools::TOOL_NAMES.size}"
        "mcp: advertising #{served} tools#{" (--read-only)" if read_only} (#{weight}); " \
        "narrow it with a --tools profile (#{MCP::ToolFilter.profile_names}) or a --tools=SPEC " \
        "of names and globs to spend less of the model's context on it"
      end
    end

    selection, bind_error = if no_project
                              {MCP::ProjectResolver::Selection.new(nil, nil, nil, "unbound"), nil}
                            else
                              resolve_mcp_project(db_path, project,
                                workspace_project: !use_active_project,
                                allow_active_fallback: use_active_project)
                            end
    project_name = selection.project_name
    project_slug = selection.project_slug
    project_id = selection.project_id

    unless selection.bound?
      log_unbound_binders(advertised, tools_spec, read_only)
      server = MCP::Server.new(nil, allow_actions: !read_only, verify_upstream: !insecure_upstream,
        project_name: nil, project_slug: nil, db_path: nil,
        selection_source: selection.source, workspace_root: nil, project_id: nil,
        bind_error: bind_error, tool_filter: tool_filter)
      server.run
      return
    end

    resolved = selection.db_path.not_nil!
    Log.info { "mcp: serving #{resolved}#{" (#{project_name})" if project_name}#{" [#{project_slug}]" if project_slug} source=#{selection.source} (actions=#{!read_only})" }
    if selection.auto_created
      Log.warn { "mcp: created an isolated project for workspace #{selection.workspace_root}; use --project/--db to override" }
    elsif selection.source.in?("active-tui", "mru", "default-db")
      Log.warn { "mcp: no source workspace or explicit selector — defaulting via #{selection.source} to #{resolved}" }
    end

    # Opening a non-SQLite / unreadable file raises deep in the driver. Aborting here
    # would kill the process BEFORE the handshake, and every MCP client reports that as
    # "the server failed to start" — the reason lands in a log the agent cannot read and
    # the human rarely opens. So degrade to the unbound mode this server already has:
    # the handshake succeeds, the reason rides on `instructions` and on every NO_PROJECT
    # tool error, and list_projects / switch_project — the very tools that fix it — stay
    # reachable. A dead server can only be repaired by hand; a degraded one repairs itself.
    # `Error` is rescued alongside the driver's types, not just them: `Store.open` names the
    # two cases it can diagnose itself — a file that is not a database, and a schema written
    # by a NEWER gori — as a `Gori::Error`. Both are exactly the "degrade to unbound"
    # situation below, and leaving them out would let the CLEARER of the two messages be the
    # one that kills the server before the handshake.
    store =
      begin
        # never prune the user's history; and under --read-only, never WRITE it either —
        # a store that only reads starts no writer fiber, so this process stops competing
        # for SQLite's single writer slot with the TUI capturing into the same db (#752).
        # Even with actions on, skip the idle FTS drain: `index_pending!` still runs on a
        # `body:` query, and an idle tick against a capturing TUI is the #752 condition.
        Store.open(resolved, events: nil, retention_flows: Store::RETENTION_UNLIMITED,
          read_only: read_only, background_index: false)
      rescue ex : DB::Error | SQLite3::Exception | Error
        reason = "cannot open database #{resolved}: #{ex.message.presence || "not a valid SQLite database (or unreadable)"}"
        Log.error { "mcp: #{reason}; starting unbound" }
        # The DEGRADED start is unbound too, and is the one the operator is most likely to be
        # watching — so it gets the same binder check the deliberate `--no-project` start
        # gets. Without it, a filtered server whose database would not open told the agent
        # "the operator must restart" while the operator's own stderr said only that the file
        # was bad (#1136).
        log_unbound_binders(advertised, tools_spec, read_only)
        server = MCP::Server.new(nil, allow_actions: !read_only, verify_upstream: !insecure_upstream,
          project_name: nil, project_slug: nil, db_path: nil,
          selection_source: "unbound", workspace_root: nil, project_id: nil,
          bind_error: reason, tool_filter: tool_filter)
        server.run
        return
      end
    Log.warn { "mcp: #{resolved} has no captured flows (empty database)" } if store.count.zero?
    begin
      server = MCP::Server.new(store, allow_actions: !read_only, verify_upstream: !insecure_upstream,
        project_name: project_name, project_slug: project_slug, db_path: resolved,
        selection_source: selection.source, workspace_root: selection.workspace_root,
        project_id: project_id, tool_filter: tool_filter)
      server.run # blocks until STDIN EOF (client closed)
    ensure
      store.close
    end
  end

  # Writes the MCP entry into every named client config. Returns false if ANY target
  # failed — reported per target, and never as an abort partway through, which would have
  # made "which clients did gori configure?" depend on the order the flags were typed in.
  # What the operator is told about an unbound start, named from what this process will
  # ACTUALLY advertise rather than from the three tools that exist. `--tools` can remove every
  # one of them, and a server left without a PICKER (`switch_project` / `create_project`)
  # cannot be repaired from the agent's side at all — `list_projects` lists and binds nothing,
  # so serving it alone buys the agent a listing and a refusal per entry. That is an operator
  # mistake, made at start-up, and stderr is the only surface the operator is looking at when
  # it is made — the agent never sees it (#1136).
  private def self.log_unbound_binders(advertised : Array(String), tools_spec : String?,
                                       read_only : Bool) : Nil
    if MCP::Tools::PROJECT_PICKERS.none? { |n| advertised.includes?(n) }
      Log.warn do
        spec = tools_spec ? "--tools=#{tools_spec} advertises" : "this server advertises"
        "mcp: unbound (no project) and #{spec} neither of " \
        "#{MCP::Tools::PROJECT_PICKERS.join(", ")} — no call can bind a project. " \
        "Restart with --project/--db, or add switch_project to --tools"
      end
    else
      usable = MCP::Tools::PROJECT_BINDERS.select { |n| advertised.includes?(n) }
      Log.info { "mcp: unbound (no project); use #{usable.join(" / ")} (actions=#{!read_only})" }
    end
  end

  private def self.install_mcp_config(targets : Array(String), db_path : String?, project : String?,
                                      read_only : Bool, insecure_upstream : Bool,
                                      use_active_project : Bool, no_project : Bool,
                                      settings_path : String?, tools_spec : String? = nil) : Bool
    exe = MCP::Install.executable_path
    outcomes = MCP::Install.install_all(targets, exe_path: exe, db_path: db_path, project: project,
      read_only: read_only, insecure_upstream: insecure_upstream,
      use_active_project: use_active_project, no_project: no_project,
      settings_path: settings_path, tools_spec: tools_spec)
    outcomes.each do |outcome|
      if path = outcome.path
        puts "Successfully installed gori MCP server configuration to #{path}"
        if outcome.target == "pi"
          puts "Pi requires an MCP adapter (e.g. pi install npm:pi-mcp-adapter). Restart Pi to load the configuration."
        end
      else
        STDERR.puts "Failed to install MCP config for #{outcome.target}: #{outcome.error}"
      end
    end
    # Once, and read back off an Outcome: the argv is identical for every target, and this
    # is the array the installs actually wrote rather than a second build of it.
    outcomes.first?.try { |first| puts "Command: #{exe} #{first.args.join(" ")}" }
    outcomes.all?(&.ok?)
  rescue ex
    # `executable_path` (gori invoked through a PATH entry that has since moved) and
    # `build_args` (a deleted working directory) both raise before any target is attempted.
    # Neither is a Gori::Error, so CLI.run's narrow rescue lets them out as a backtrace —
    # they were covered by this method's own rescue before it grew a loop, and a setup
    # failure affecting every target still belongs here rather than in an Outcome.
    abort "Failed to install MCP config: #{ex.message.presence || ex.class}"
  end

  # The selection, plus the reason it could not be made. A resolution failure is a
  # RUNTIME condition — a project renamed since the client config was written, a db moved
  # out from under `--db`, a HOME the process cannot write — not a usage error, and this
  # process is not run by a human who would see an abort: it is spawned by an agent
  # client that reports a non-starting server as one dead line. So NOTHING here aborts;
  # the caller starts unbound carrying the reason (see the store-open path above).
  # The rescue is deliberately blanket: `Paths.ensure_dirs` and the registry read can
  # raise `File::Error` too, and an unhandled backtrace is the same dead server with a
  # worse message.
  private def self.resolve_mcp_project(db : String?, project : String?, *, workspace_project : Bool,
                                       allow_active_fallback : Bool) : {MCP::ProjectResolver::Selection, String?}
    {MCP::ProjectResolver.resolve(db, project, workspace_project: workspace_project,
      allow_active_fallback: allow_active_fallback), nil}
  rescue ex
    reason = ex.message.presence || ex.class.name
    Log.error { "mcp: #{reason}; starting unbound" }
    {MCP::ProjectResolver::Selection.new(nil, nil, nil, "unresolved"), reason}
  end
end
