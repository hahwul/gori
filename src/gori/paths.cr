module Gori
  # XDG-style locations for gori's state. The DB lives under the data dir; the
  # CA (a machine secret + the cert the user installs) under the config dir.
  module Paths
    def self.config_dir : String
      base = ENV["XDG_CONFIG_HOME"]?.presence || File.join(Path.home.to_s, ".config")
      File.join(base, "gori")
    end

    def self.data_dir : String
      base = ENV["XDG_DATA_HOME"]?.presence || File.join(Path.home.to_s, ".local", "share")
      File.join(base, "gori")
    end

    def self.default_db : String
      File.join(data_dir, "gori.db")
    end

    # Root for per-project workspaces (each project = a subdir with its own DB).
    def self.projects_dir : String
      File.join(data_dir, "projects")
    end

    def self.default_ca_dir : String
      File.join(config_dir, "ca")
    end

    # Path to the (future) persistent user config file. `gori config` reports
    # and lazily initializes this file with a template.
    def self.config_file : String
      File.join(config_dir, "config.yml")
    end

    def self.ensure_dirs : Nil
      ensure_dir(data_dir)
      ensure_dir(config_dir)
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
