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

    # A tiny global marker holding the DB PATH of the project the interactive TUI last
    # opened. Headless integrations use this only after an explicit opt-in (for MCP,
    # `--use-active-project`); a source workspace must never silently inherit another
    # repository's active project. Path (not name) avoids display-name/slug ambiguity.
    def self.active_project_file : String
      File.join(home_dir, "active_project")
    end

    def self.write_active_project(path : String) : Nil
      ensure_dir(home_dir)
      dest = active_project_file
      tmp = "#{dest}.tmp.#{Process.pid}"
      File.write(tmp, path)
      File.rename(tmp, dest)
    rescue
      # best-effort: a missing/failed marker leaves explicit active-project lookup unavailable.
    end

    def self.read_active_project : String?
      File.read(active_project_file).strip.presence
    rescue
      nil
    end

    def self.ensure_dirs : Nil
      ensure_dir(home_dir)
      ensure_dir(projects_dir) # lock the projects ROOT too (registry only mkdir's leaves)
      ensure_dir(wordlists_dir)
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
    def self.ensure_dir(path : String) : Nil
      Dir.mkdir_p(path, DIR_MODE)
      File.chmod(path, DIR_MODE) rescue nil # tighten a pre-0700 dir from an older install
    rescue File::AlreadyExistsError
      # created concurrently by another instance — it exists now, fine
      File.chmod(path, DIR_MODE) rescue nil
    end
  end
end
