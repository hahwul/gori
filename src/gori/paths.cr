require "./durable_file"

module Gori
  # gori keeps everything under ONE directory — `~/.gori` by default, overridable
  # with `$GORI_HOME`: settings.json, the CA (machine secret + the cert the user
  # installs), per-project workspaces + their DBs, and the log. A single tree is
  # easier to find / back up / wipe than the XDG config/data split for a data-heavy
  # workspace tool (and is consistent cross-platform).
  module Paths
    def self.home_dir : String
      ENV["GORI_HOME"]?.presence || File.join(Path.home.to_s, ".gori")
    end

    def self.default_db : String
      File.join(home_dir, "gori.db")
    end

    # Root for per-project workspaces (each project = a subdir with its own DB).
    def self.projects_dir : String
      File.join(home_dir, "projects")
    end

    # User colour themes: each `*.json` here is loaded as a selectable TUI theme
    # (filename stem = theme name), merged after the built-ins. See Tui::Theme.load_custom.
    def self.themes_dir : String
      File.join(home_dir, "themes")
    end

    def self.default_ca_dir : String
      File.join(home_dir, "ca")
    end

    # Convention dir for fuzzer wordlists: bare (slash-less) names typed into the
    # Fuzzer's wordlist field auto-complete from here (and the current dir). Users
    # drop `*.txt` lists in here for discovery without typing a full path.
    def self.wordlists_dir : String
      File.join(home_dir, "wordlists")
    end

    # Convention dir for gRPC `.proto` schemas: FileDescriptorSet files (`protoc
    # --descriptor_set_out`). A project whose "Proto schema" setting is blank loads every
    # descriptor set found here, and a bare (slash-less) name typed into that field resolves
    # against it first — the same rule `wordlists_dir` gives the Fuzzer's payload field.
    def self.protos_dir : String
      File.join(home_dir, "protos")
    end

    # A tiny global marker holding the DB PATH of the project the interactive TUI last
    # opened. Headless MCP uses this only after an explicit opt-in (`--use-active-project`);
    # otherwise MCP outside a Git workspace starts unbound so the agent can list/create/
    # switch. A source workspace must never silently inherit another repository's active
    # project. Path (not name) avoids display-name/slug ambiguity.
    def self.active_project_file : String
      File.join(home_dir, "active_project")
    end

    def self.write_active_project(path : String) : Nil
      ensure_dir(home_dir)
      # Via DurableFile for its temp cleanup as much as its durability: the old staging here
      # swallowed every failure at the method-level rescue and left `active_project.tmp.<pid>`
      # behind, and nothing in the tree ever swept those.
      DurableFile.write(active_project_file, path, perm: File::Permissions.new(0o644))
    rescue
      # best-effort: a missing/failed marker leaves explicit active-project lookup unavailable.
    end

    def self.read_active_project : String?
      File.read(active_project_file).strip.presence
    rescue
      nil
    end

    # A path canonicalized for IDENTITY comparison — the same file reached by a different
    # spelling must compare equal. `realpath` on the file when it exists; otherwise on its
    # DIRECTORY plus the basename, because a path naming something not created yet is legitimate
    # (only its parent has to exist) and `realpath` raises on a missing leaf.
    #
    # Two things need this and reached it independently: matching a `--db` against the registry's
    # own `db_path` (built from `$GORI_HOME` exactly as spelled), and keying `OpenLock` so one
    # database cannot end up with two lock files. `$GORI_HOME` behind a symlink — a dotfiles-managed
    # home, `/tmp` on macOS — is the ordinary way to hit both.
    def self.canonical_file(path : String) : String
      return File.realpath(path) if File.exists?(path)
      File.join(File.realpath(File.dirname(path)), File.basename(path))
    rescue
      path
    end

    def self.ensure_dirs : Nil
      ensure_dir(home_dir)
      ensure_dir(projects_dir) # lock the projects ROOT too (registry only mkdir's leaves)
      ensure_dir(wordlists_dir)
      # …and the `.proto` convention dir beside it (#823), for the same reason: the Project
      # pane's blank-field placeholder, the CHANGELOG and the config reference all tell an
      # operator to drop a descriptor set in here, and a directory that does not exist yet is
      # a worse answer than an empty one.
      ensure_dir(protos_dir)
    end

    # gori's tree holds captured traffic (per-project DBs), the CA private key, and
    # settings.json — secrets other local users on a shared host must not read. So
    # every gori dir is owner-only 0700, NOT left at the umask default (a fresh
    # `~/.gori` was 0755 = world-traversable, exposing world-readable project DBs
    # underneath). 0700 has no group/other bits for any umask to strip, so
    # `mkdir_p(mode)` yields it exactly; the explicit chmod additionally tightens a
    # pre-existing 0755 dir from an older install. Mirrors cert_authority.cr locking
    # the CA key to 0600 rather than trusting umask.
    DIR_MODE = 0o700

    # Race-tolerant `mkdir -p` at 0700 (see DIR_MODE): two gori instances can start
    # simultaneously and both create a fresh dir — one wins the mkdir, the other must
    # not crash.
    #
    # `tighten: false` keeps the 0700 creation but skips the chmod on a directory that was
    # ALREADY there. The distinction is ownership, not mode: a directory gori makes is gori's
    # to lock down, one it merely FINDS belongs to whoever made it. Every caller but one names
    # a path inside GORI_HOME, where the two are the same thing — but `gori --config PATH`
    # takes an arbitrary path, and its parent can be a shared checkout, a dotfiles repo, or
    # (for a relative `--config`) the working directory. Silently stripping group/other off
    # those is a side effect nobody asked for, and it is not what protects the file anyway:
    # the settings file itself is written 0600 (see Settings.write_private).
    def self.ensure_dir(path : String, *, tighten : Bool = true) : Nil
      ours = !Dir.exists?(path) # sampled BEFORE the mkdir: only a dir we create is ours to mode
      begin
        Dir.mkdir_p(path, DIR_MODE)
      rescue File::AlreadyExistsError
        # created concurrently by another instance — it exists now, at DIR_MODE already
        ours = false
      end
      # mkdir_p raises AlreadyExists for BOTH "another instance won the race" and "a plain
      # FILE occupies this path", and only the first is benign. Say which, here, while the
      # path is still in hand: left to the caller it surfaces however far downstream the
      # first write happens to be — `gori ca --ca-dir notes.txt` reported
      # `BIO_new_file(notes.txt/root.crt.pem) failed`, which names neither the argument the
      # operator typed nor what is wrong with it.
      raise Gori::Error.new("path exists and is not a directory: #{path}") unless Dir.exists?(path)
      # 0700 has no group/other bits for any umask to strip, so a dir we created is already
      # exact; the chmod is for a pre-0700 dir from an older install.
      File.chmod(path, DIR_MODE) rescue nil if ours || tighten
    end
  end
end
