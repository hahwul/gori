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

    def self.default_ca_dir : String
      File.join(home_dir, "ca")
    end

    def self.ensure_dirs : Nil
      ensure_dir(home_dir)
    end

    # Race-tolerant `mkdir -p`: two gori instances can start simultaneously and
    # both create a fresh dir — one wins the mkdir, the other must not crash.
    def self.ensure_dir(path : String) : Nil
      Dir.mkdir_p(path)
    rescue File::AlreadyExistsError
      # created concurrently by another instance — it exists now, fine
    end
  end
end
