require "file_utils"

module Gori
  # A workspace: a named SQLite DB, so each project's history/sitemap/etc. are
  # isolated (P5). A "temp" project is ephemeral and its directory is removed
  # when the session closes.
  struct Project
    DB_FILE = "gori.db"

    getter name : String
    getter db_path : String
    getter? ephemeral : Bool

    def initialize(@name : String, @db_path : String, @ephemeral : Bool = false)
    end

    def dir : String
      File.dirname(@db_path)
    end

    # Best-effort last-activity time (DB file mtime), for the picker.
    def last_modified : Time?
      File.exists?(@db_path) ? File.info(@db_path).modification_time : nil
    end

    # On-disk size of the SQLite DB (shown as "DB Size" in the Project tab).
    def db_size : Int64
      File.exists?(@db_path) ? File.info(@db_path).size : 0_i64
    end

    # Best-effort project creation time (project dir mtime from mkdir in registry;
    # falls back to earliest flow activity inside the Project tab view).
    def created : Time?
      d = dir
      Dir.exists?(d) ? File.info(d).modification_time : nil
    end

    # Remove the workspace from disk (temp projects only).
    def cleanup : Nil
      FileUtils.rm_rf(dir) if @ephemeral && Dir.exists?(dir)
    end
  end
end
