require "file_utils"
require "./capture_lock"
require "./capture_status"

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

    # Path of this project's advisory capture lock — keyed on the DB FILE, not the parent
    # directory, so two independent `--db` databases that happen to share a directory don't
    # falsely serialize (each is its own database with its own capture session). The canonical
    # registry db (DB_FILE) keeps the legacy per-directory lock path (`<dir>/.capture.lock`),
    # so the registry's directory-based CaptureLock.held? guards (delete/rename) still detect a
    # live capturer with no regression.
    def capture_lock_path : String
      sidecar_path(CaptureLock.path(dir), ".capture.lock")
    end

    # Path of this project's capture-status marker, keyed exactly like the lock above and for
    # the same reason: the marker DESCRIBES the capture the lock guards, so if the two are
    # keyed differently they describe different things. They were — the lock on the db file,
    # the marker on the parent directory — so two `--db` databases sharing a directory, which
    # correctly hold independent locks and capture at the same time, shared ONE marker: the
    # second session's bind address overwrote the first's, and whichever closed first deleted
    # the marker belonging to a session still live. The picker reads that marker to say where
    # a project opened in another window is listening, so it reported the wrong port, or a
    # live project with no address.
    #
    # The canonical registry db keeps the legacy per-directory path, so the picker's
    # `CaptureStatus.read(project.dir)` (and every existing marker on disk) is unchanged.
    def capture_status_path : String
      sidecar_path(CaptureStatus.path(dir), ".capture.status")
    end

    # The keying rule the two sidecars above share, expressed once: the canonical registry db
    # keeps its LEGACY per-directory path (so every marker already on disk, and every dir-based
    # probe, keeps working), and anything else — a `--db` file — is keyed on the DATABASE. Their
    # own comments insist the two must agree, which is an invariant a second copy of the ternary
    # can only weaken: a third sidecar, or a change to what counts as canonical, would have to be
    # applied everywhere for it to hold.
    private def sidecar_path(legacy : String, suffix : String) : String
      canonical? ? legacy : "#{@db_path}#{suffix}"
    end

    # Whether this database carries the CANONICAL registry filename (`gori.db`), as opposed to
    # an arbitrary `--db PATH` file that merely borrows a parent directory.
    #
    # NOT the same question as "is this a registry project": a `--db` aimed at some other
    # project's own `gori.db` (a backup, a copy under another root) answers true here while its
    # directory is not one the registry owns. Anything reading the registry's `.id` /
    # `.workspace` sidecars must ALSO check the parent against `Paths.projects_dir` — see
    # `ProjectView#registry_project?`, which is exactly that pairing.
    #
    # Extracted from `sidecar_path` rather than copied at the new call site, because the rule
    # above insists the two sidecars agree about it. One predicate, so a change to what counts
    # as canonical lands everywhere at once.
    def canonical? : Bool
      File.basename(@db_path) == DB_FILE
    end

    # A one-line, operator-readable reason this project's store would not open, for a
    # surface that has nowhere to put a backtrace (the TUI picker). The exception alone is
    # useless there: SQLite answers "the parent directory does not exist", "this file is not
    # a database" and "no read permission" with the same DB::ConnectionRefused. So name the
    # case from the PATH, which is what the operator can actually act on, and fall back to
    # the raw message only for what the path cannot explain. Wording mirrors what
    # `gori run --db` aborts with, so both surfaces describe one failure one way.
    def open_failure_reason(ex : Exception) : String
      parent = File.dirname(@db_path)
      # A message that already names this db is a complete sentence — `Store.open` raises one
      # for the case it diagnoses itself ("cannot open <path>: not a valid SQLite database"),
      # and re-deriving a guess from the path below would replace a true reason with a weaker
      # one while printing the path twice. Anything that does NOT name the path still gets
      # wrapped, so the project name the picker needs is not lost (a bare "disk is full").
      if (msg = ex.message.presence) && msg.includes?(@db_path)
        return msg
      end
      return "cannot open #{@db_path}: no such directory: #{parent}" unless Dir.exists?(parent)
      if File.exists?(@db_path) && (ex.is_a?(DB::Error) || ex.is_a?(SQLite3::Exception))
        return "cannot open #{@db_path}: not a valid SQLite database (or unreadable)"
      end
      "could not open '#{@name}': #{ex.message.presence || ex.class}"
    end

    # Best-effort last-activity time (DB file mtime), for the picker.
    #
    # `File.info?` + rescue, not `File.exists?` then `File.info`: that pair is a TOCTOU
    # window a PEER closes routinely — `ProjectRegistry#delete` and MCP `delete_project`
    # `rm_rf` the workspace, so the file can vanish between the two calls and `File.info`
    # raises `File::NotFoundError` out of `ProjectRegistry#list`'s `sort_by!`, the picker's
    # row render and MCP `list_projects`. `File.info?` closes the vanish case; the rescue
    # covers the one it does not (an unreadable parent raises `File::AccessDeniedError`).
    # `disk_size` below already takes exactly this stance per entry.
    def last_modified : Time?
      File.info?(@db_path).try(&.modification_time)
    rescue File::Error
      nil
    end

    # On-disk size of the SQLite DB (shown as "DB Size" in the Project tab).
    def db_size : Int64
      File.info?(@db_path).try(&.size) || 0_i64
    rescue File::Error
      0_i64
    end

    # Total bytes of every file under the project directory (DB + WAL/SHM + the dotfile
    # sidecars), for the "this is what you are deleting" previews. Walks with Dir.children
    # rather than Dir.glob: a glob pattern is built from the projects ROOT, so a home
    # directory holding `[`, `*` or `?` would silently match nothing and report 0 bytes for
    # a multi-GB capture — the one number an operator reads before confirming an
    # irreversible delete. Best-effort otherwise: anything that vanishes or is unreadable
    # mid-walk is skipped rather than raising.
    #
    # Meaningful only for a REGISTRY project, whose `dir` is its own workspace. A Project
    # built from an explicit `--db PATH` borrows an arbitrary parent directory, and walking
    # that is neither cheap nor meaningful.
    def disk_size : Int64
      d = dir
      return 0_i64 unless Dir.exists?(d)
      total = 0_i64
      pending = [d]
      while current = pending.pop?
        children = begin
          Dir.children(current)
        rescue
          next # a directory that vanished or became unlistable mid-walk
        end
        children.each do |child|
          path = File.join(current, child)
          info = File.info(path, follow_symlinks: false)
          if info.directory?
            pending << path
          else
            total += info.size
          end
        rescue
          # skip anything that vanished / is unreadable mid-walk
        end
      end
      total
    end

    # Best-effort project creation time (project dir mtime from mkdir in registry;
    # falls back to earliest flow activity inside the Project tab view).
    def created : Time?
      File.info?(dir).try { |i| i.directory? ? i.modification_time : nil }
    rescue File::Error
      nil # same best-effort stance as `last_modified` — a peer may be deleting this project
    end

    # Remove the workspace from disk (temp projects only).
    def cleanup : Nil
      FileUtils.rm_rf(dir) if @ephemeral && Dir.exists?(dir)
    end
  end
end
