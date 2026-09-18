require "json"
require "../paths"
require "../durable_file"
require "../mcp/install"

module Gori
  module Agent
    # The `--mcp-config` file an agent spawn is handed: one entry, pointing the child at a
    # `gori mcp` server bound to THIS project's database (#1093).
    #
    # Written rather than passed inline because that is the only shape the backends take — a
    # path to a JSON file — and because the file has to outlive the spawn that reads it.
    module McpConfig
      # The directory suffix, the `.agents`/`.windows` convention `AgentPresence` established:
      # a sibling of the database file, keyed on its CANONICAL path, so one database cannot
      # grow two of them through a `--db` spelling difference or a symlinked `$GORI_HOME`.
      DIR_SUFFIX = ".agent"

      FILE_NAME = "mcp.json"

      # Write the config and answer its path.
      #
      # WHY NOT `/tmp`. The obvious shape for a file handed to a child process is a temp file,
      # and it is wrong twice here. First, it leaks: the system temp directory is world-readable
      # on every platform gori runs on, and this file NAMES the project database — an absolute
      # path that identifies the engagement, the client, and often the target, to every other
      # user on a shared host. A 0600 file does not help when the directory ENTRY is the
      # disclosure. Second, it does not survive: a per-spawn temp path means a new file for
      # every resume, a fresh one after every reboot's `/tmp` sweep, and nothing an operator
      # can look at to answer "what is my agent actually connected to". A stable path beside
      # the database is one file per project, at 0700/0600, that says what it is by where it is.
      #
      # Idempotent — the same project always produces the same path and the same bytes for the
      # same `read_only`, so a resume overwrites its own file rather than accumulating.
      def self.write(db_path : String, read_only : Bool) : String
        dir = dir_for(db_path)
        Paths.ensure_dir(dir) # 0700 — see Paths::DIR_MODE
        path = File.join(dir, FILE_NAME)
        DurableFile.write(path, json(db_path, read_only),
          # 0600 and `inherit: false`: the mode is dictated, not preserved. A file found at
          # 0644 — written by an older build, or by an operator's editor — must come back
          # narrowed rather than keep the wider mode, which is the distinction `DurableFile`
          # draws for settings.json (it holds env token values) and which applies here for the
          # same reason: this names the project database to whoever can read it.
          perm: File::Permissions.new(0o600), inherit: false)
        path
      end

      # `<canonical db path>.agent/`. Through `Paths.canonical_file`, the rule `OpenLock.path`
      # and `AgentPresence.dir_for` both use, so the marker directory, the presence directory
      # and this one all key off one spelling of the database.
      def self.dir_for(db_path : String) : String
        "#{Paths.canonical_file(db_path)}#{DIR_SUFFIX}"
      end

      # The `mcpServers` document, built rather than interpolated so a path containing a quote
      # or a backslash cannot produce a file the child parses as something else.
      #
      # The argv comes from `MCP::Install.build_args`, the same builder that writes gori into a
      # client's own config. Reused on purpose: that method's comment is the record of what
      # happens when a flag is spelled in a second place — `--no-project` and `--config` were
      # each dropped by a hand-written copy, leaving a server bound to the wrong workspace with
      # nothing to say so. A flag this file needs later is a flag that belongs there.
      def self.json(db_path : String, read_only : Bool) : String
        args = MCP::Install.build_args(db_path: db_path, read_only: read_only)
        entry = {
          "command" => JSON::Any.new(MCP::Install.executable_path),
          "args"    => JSON::Any.new(args.map { |a| JSON::Any.new(a) }),
        }
        servers = {MCP::Install::SERVER_NAME => JSON::Any.new(entry)}
        {"mcpServers" => JSON::Any.new(servers)}.to_pretty_json
      end
    end
  end
end
