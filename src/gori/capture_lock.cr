module Gori
  # Advisory capture lock keyed on the DB FILE. The FIRST live instance to open a
  # database holds a lock file (BSD flock) for the session's lifetime; a SECOND
  # instance of the SAME database fails to acquire it and opens VIEW-ONLY (no second
  # listener — it live-refreshes off the shared DB via the data_version poll). A
  # DIFFERENT database — even one sharing the same directory, e.g. two `--db` files —
  # has its OWN lock file, so it still captures on its own port. Callers hand in the
  # lock-file path via `try_at`/`held_at?` (see Project#capture_lock_path, which keys
  # it on the db file: `<db_path>.capture.lock`). The legacy `try`/`held?`/`path`
  # take a DIRECTORY and lock `<dir>/.capture.lock`; the canonical registry db keeps
  # that per-directory path so the registry's dir-based `held?` guards (delete/rename)
  # still detect a live capturer with no regression. The lock is auto-released when
  # the File is closed OR when the owning process dies (flock is per open-file-
  # description, freed by the kernel on close / exit).
  #
  # Caveats: flock is advisory and a no-op on many network filesystems (NFS), so on
  # such a mount the lock gives no protection — the proxy's own port-probe fallback
  # is the second line of defense. The lock FILE persists (empty) after release;
  # its mere existence is NOT "held" — only a FAILED flock means another instance
  # is capturing.
  class CaptureLock
    LOCK_FILE = ".capture.lock"

    # The legacy per-DIRECTORY lock path (`<dir>/.capture.lock`).
    def self.path(dir : String) : String
      File.join(dir, LOCK_FILE)
    end

    # Non-blocking probe on the DIRECTORY lock: true when another LIVE instance holds it.
    def self.held?(dir : String) : Bool
      held_at?(path(dir))
    end

    # Non-blocking probe on an explicit LOCK FILE PATH: true when another LIVE instance
    # already holds it. Opens and immediately releases when free. Non-contention failures
    # from `try_at` (EACCES, unwritable dir, …) propagate to the caller.
    def self.held_at?(lock_path : String) : Bool
      lock = try_at(lock_path)
      if lock
        lock.close
        false
      else
        true
      end
    end

    # Try to acquire the DIRECTORY lock (`<dir>/.capture.lock`) WITHOUT blocking.
    def self.try(dir : String) : CaptureLock?
      try_at(path(dir))
    end

    # Try to acquire the lock at an explicit LOCK FILE PATH WITHOUT blocking. Returns a held
    # CaptureLock (the caller MUST keep it alive for the session and `close` it on session
    # end) when this instance is the capturer, or nil when another LIVE instance already holds
    # it. A non-contention failure (can't create the dir, open EACCES, …) is RE-RAISED so it
    # is never mistaken for "someone else holds it".
    def self.try_at(lock_path : String) : CaptureLock?
      dir = File.dirname(lock_path)
      # `Paths.ensure_dir`, not a bare `Dir.mkdir_p` — the same call, with the same argument,
      # that `CaptureStatus.write_at` makes for THIS VERY DIRECTORY (capture_status.cr, which
      # spells out the reasoning): every gori dir is owner-only 0700 because the captured
      # traffic DB lands in it, and a plain mkdir_p leaves it at the umask, world-traversable
      # on a shared host. This is the sibling that never got that fix, and the loose mode would
      # be permanent — `capture_status`'s deliberate `tighten: false` never tightens an
      # existing dir. `tighten: false` here for the same reason it is there: a `--db` project
      # can borrow a parent directory that is not gori's to chmod.
      Paths.ensure_dir(dir, tighten: false) # a headless Project has no registry mkdir
      file = File.open(lock_path, "w")
      begin
        file.flock_exclusive(blocking: false) # => Nil on success; RAISES IO::Error if held
        new(file)
      rescue IO::Error
        file.close rescue nil # contended — release our fd, no leak
        nil
      rescue ex
        file.close rescue nil # open/other failure: don't masquerade as "held"
        raise ex
      end
    end

    def initialize(@file : File)
    end

    # Release the flock (closing the fd is enough; the explicit unlock is belt-and-
    # suspenders). Safe to call once at session close.
    def close : Nil
      @file.flock_unlock rescue nil
      @file.close rescue nil
    end
  end
end
