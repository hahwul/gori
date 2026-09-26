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
      p.on("--insecure-upstream", "Skip upstream TLS verification for every tool that sends (send_request, fuzz, grpc_reflect, session refresh, OAST, …)") { insecure_upstream = true }
      p.on("--read-only", "Disable action tools (send_request, create/update_issue); serve the project without a writer") { read_only = true }
      p.on("--tools=SPEC", mcp_tools_help) { |v| tools_spec = v }
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
      case parsed = MCP::ToolFilter.parse(spec, MCP::Tools::TOOL_NAMES,
        MCP::Tools::TOOL_DEPENDENCIES)
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
    # Preferences › AI › MCP permissions, latched for this process like `mcp_channels`, and
    # never failing open: a settings file this start could not read in full denies every group
    # rather than serving them all (`mcp_enforced_denials`).
    denied, denial_warning = Settings.mcp_enforced_denials
    Log.warn { "mcp: #{denial_warning}" } if denial_warning
    unless (groups = Settings.mcp_permission_groups(denied)).empty?
      Log.info { "mcp: switched off in Preferences (AI › MCP permissions): #{groups.join(", ", &.title)}" }
      advertised = MCP::Tools.served_names(tool_filter, !read_only, denied)
      # The `--read-only` refusal above, for the switches: a spec whose every tool is in a
      # group the operator turned off would start a server with an empty tools/list, which an
      # agent cannot tell from a gori without the feature. Refused here, AFTER the install
      # branch — an installed command outlives today's switches.
      if tool_filter && advertised.empty?
        abort "gori mcp: every tool --tools=#{tools_spec} selects is switched off in Preferences " \
              "(AI › MCP permissions: #{groups.join(", ", &.title)}), so the server would advertise " \
              "nothing. Allow a group there, or name a read tool."
      end
    end

    # The catalogue is the first thing this server spends, and it spends it on the operator's
    # behalf before a question is asked: an MCP client loads every tool description into the
    # model's context and keeps it there for the session. Said on EVERY start — which is why
    # it is HERE and not beside the bound server below: an unbound start (outside a git
    # workspace, `--no-project`, or a database that would not open) spends exactly the same
    # context and used to say nothing at all.
    Log.info { mcp_catalogue_banner(tool_filter, read_only, denied) }

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
      log_unbound_binders(advertised, tool_filter, read_only, denied)
      server = MCP::Server.new(nil, allow_actions: !read_only, verify_upstream: !insecure_upstream,
        project_name: nil, project_slug: nil, db_path: nil,
        selection_source: selection.source, workspace_root: nil, project_id: nil,
        bind_error: bind_error, tool_filter: tool_filter, denied_permissions: denied)
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
        log_unbound_binders(advertised, tool_filter, read_only, denied)
        server = MCP::Server.new(nil, allow_actions: !read_only, verify_upstream: !insecure_upstream,
          project_name: nil, project_slug: nil, db_path: nil,
          selection_source: "unbound", workspace_root: nil, project_id: nil,
          bind_error: reason, tool_filter: tool_filter, denied_permissions: denied)
        server.run
        return
      end
    Log.warn { "mcp: #{resolved} has no captured flows (empty database)" } if store.count.zero?
    begin
      server = MCP::Server.new(store, allow_actions: !read_only, verify_upstream: !insecure_upstream,
        project_name: project_name, project_slug: project_slug, db_path: resolved,
        selection_source: selection.source, workspace_root: selection.workspace_root,
        project_id: project_id, tool_filter: tool_filter, denied_permissions: denied)
      server.run # blocks until STDIN EOF (client closed)
    ensure
      store.close
    end
  end

  # The `--tools` help. No size in it: this text is compiled in, and every number ever
  # written here had drifted by the time #1137 measured it — the startup log weighs the
  # catalogue it is about to serve instead. The profile column is as wide as the longest
  # name, not a fixed `ljust`, which pads only when the value is SHORTER and would run a
  # longer profile's name straight into its summary.
  def self.mcp_tools_help : String
    width = MCP::ToolFilter::PROFILES.max_of(&.name.size) + 3
    String.build do |io|
      io << "Advertise only these tools: comma-separated names, globs or @profiles,\n"
      io << "'-' subtracts (e.g. '@recon', '@minimal,send_request', '-fuzz_*,-mine_*').\n"
      io << "Required companions are included automatically; conflicting explicit exclusions are refused.\n"
      io << "The client loads every advertised tool into the model's context; the\n"
      io << "startup log says how much. Profiles:"
      MCP::ToolFilter::PROFILES.each do |pr|
        io << "\n  " << "@#{pr.name}".ljust(width) << pr.summary
      end
    end
  end

  # The start-up line that says what this server's catalogue costs.
  #
  # Said on EVERY start, bound or not (see the call site), and the count is what this process
  # will actually advertise, gate included; "all 179 tools (--read-only)" overstated a
  # 62-tool catalogue by threefold, on the one line whose whole job is that number. The
  # WEIGHT is measured from the very listing the client will be handed, rather than written
  # into help or docs, for the reason `mcp_tools_help` gives. One JSON build per start — the
  # same work the server's first `declared_args` does again, off any hot path.
  def self.mcp_catalogue_banner(tool_filter : MCP::ToolFilter?, read_only : Bool,
                                denied : Set(String)? = nil) : String
    advertised = MCP::Tools.served_names(tool_filter, !read_only, denied)
    total = MCP::Tools::TOOL_NAMES.size
    weight = MCP::Tools.catalogue_weight(tool_filter, !read_only, denied)
    if f = tool_filter
      "mcp: --tools=#{f.spec} advertises #{advertised.size} of #{total} tools (#{weight}): #{advertised.sort.join(", ")}"
    else
      served = advertised.size == total ? "all #{advertised.size}" : "#{advertised.size} of #{total}"
      "mcp: advertising #{served} tools#{" (--read-only)" if read_only} (#{weight}); " \
      "narrow it with a --tools profile (#{MCP::ToolFilter.profile_names}) or a --tools=SPEC " \
      "of names and globs to spend less of the model's context on it"
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
  private def self.log_unbound_binders(advertised : Array(String), tool_filter : MCP::ToolFilter?,
                                       read_only : Bool, denied : Set(String)) : Nil
    tools_spec = tool_filter.try(&.spec)
    if MCP::Tools::PROJECT_PICKERS.none? { |n| advertised.includes?(n) }
      Log.warn do
        spec = tools_spec ? "--tools=#{tools_spec} advertises" : "this server advertises"
        fixes = [] of String
        if MCP::Tools.denied_permission(denied, "switch_project")
          fixes << "allow Manage projects in Preferences (AI › MCP permissions)"
        end
        # Every cause that removed the binder, not the first one found: fixing one of two
        # leaves the server exactly as unbindable as it was.
        if fixes.empty? || (tool_filter && !tool_filter.allows?("switch_project"))
          fixes << "add switch_project to --tools"
        end
        fix = "or #{fixes.join(" and ")}"
        "mcp: unbound (no project) and #{spec} neither of " \
        "#{MCP::Tools::PROJECT_PICKERS.join(", ")} — no call can bind a project. " \
        "Restart with --project/--db, #{fix}"
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
