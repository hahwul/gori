module Gori
  # Per-PROJECT advisory capture lock. The FIRST live instance to enter a project
  # holds `<project.dir>/.capture.lock` (BSD flock) for the session's lifetime; a
  # SECOND instance of the SAME project fails to acquire it and opens VIEW-ONLY
  # (no second listener — it live-refreshes off the shared DB via the data_version
  # poll). A different project has a different dir, hence its own lock, so it still
  # captures on its own port. The lock is auto-released when the File is closed OR
  # when the owning process dies (flock is per open-file-description, freed by the
  # kernel on close / exit).
  #
  # Caveats: flock is advisory and a no-op on many network filesystems (NFS), so on
  # such a mount the lock gives no protection — the proxy's own port-probe fallback
  # is the second line of defense. The lock FILE persists (empty) after release;
  # its mere existence is NOT "held" — only a FAILED flock means another instance
  # is capturing.
  class CaptureLock
    LOCK_FILE = ".capture.lock"

    def self.path(dir : String) : String
      File.join(dir, LOCK_FILE)
    end

    # Try to acquire the project's capture lock WITHOUT blocking. Returns a held
    # CaptureLock (the caller MUST keep it alive for the session and `close` it on
    # session end) when this instance is the capturer, or nil when another LIVE
    # instance already holds it. A non-contention failure (can't create the dir,
    # open EACCES, …) is RE-RAISED so it is never mistaken for "someone else holds
    # it".
    def self.try(dir : String) : CaptureLock?
      Dir.mkdir_p(dir) unless Dir.exists?(dir) # a headless Project has no registry mkdir
      file = File.open(path(dir), "w")
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
