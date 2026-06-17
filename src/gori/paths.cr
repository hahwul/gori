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

    def self.ensure_dirs : Nil
      Dir.mkdir_p(data_dir)
      Dir.mkdir_p(config_dir)
    end
  end
end
