require "./paths"

module Gori
  # Advisory "a process has this DATABASE open" lock — a SHARED flock every `Store.open` takes
  # and every `Store#close` releases. Many holders coexist (that is what shared means: two TUIs,
  # a TUI plus an MCP server, a short-lived count), and an EXCLUSIVE acquire fails while any of
  # them is alive, which is the one question a destructive project operation has to answer.
  #
  # WHY IT IS NOT THE CAPTURE LOCK. `CaptureLock` answers "who is the capturer", and it must:
  # exactly one instance listens, and a second one opens view-only. `delete` used to ask THAT
  # question, and its comment states the harm precisely — "rm_rf would unlink the db out from
  # under the capturer, which would then keep 'successfully' writing flows into a now-pathless
  # inode — a silent, total loss of everything captured after the delete". The harm has nothing
  # to do with capturing, though. An MCP server takes no capture lock and writes issues, notes,
  # repeaters and fuzz history all the same, so one MCP server could delete the project another
  # was serving: reproduced with two servers, where the second kept answering
  # `{"id":2,"message":"Note created successfully"}` and reading its notes back while nothing
  # existed on disk. The lock this file adds is the question that was actually being asked.
  #
  # Keyed on the DATABASE, CANONICALIZED (`Paths.canonical_file`) — no legacy per-directory form
  # to preserve, unlike `Project#capture_lock_path`. Canonical because the two sides reach this
  # from different spellings of one path: the registry builds `db_path` from `$GORI_HOME` as it
  # was given, while `gori --db` takes whatever the operator typed. `$GORI_HOME` through a
  # symlink (a dotfiles-managed home, `/tmp` on macOS) would otherwise give one database two
  # lock files, and a probe against the wrong one answers "nobody has it open".
  #
  # BEST EFFORT with ONE carve-out. A project directory that cannot be written yields no lock
  # rather than a failed open, a filesystem whose flock does not work yields no lock, and a
  # destructive caller that could not lock anything proceeds rather than being blocked forever:
  # all of those degrade to the behaviour that existed before this class. The carve-out is a live
  # EXCLUSIVE holder that is STILL there after `try_shared`'s whole retry budget — see the raise
  # there. Opening past that one is not a degradation, it is the specific loss this class exists
  # to stop (a database being VACUUMed or rm_rf'd, with nothing announcing us to the process
  # doing it), so it is the one failure that becomes a sentence instead of a silent open. Same
  # flock caveats as `CaptureLock`: advisory, and a no-op on some network filesystems.
  class OpenLock
    SUFFIX = ".open.lock"

    # How long `try_shared` keeps trying before it refuses, and how long it waits between
    # attempts.
    #
    # An exclusive holder is only ever a destructive operation's guard — but "brief" was wrong
    # about how long those hold it. `Store::Compact` holds it across the strip AND the VACUUM,
    # which is upwards of a second on a mid-size project, and `ProjectRegistry#delete` holds it
    # across an `rm_rf`. Six attempts 3 ms apart is ~18 ms, so an open landing anywhere inside a
    # compact gave up essentially every time — and gave up by returning nil, which used to mean
    # the store opened with nothing announcing it. Reproduced: an INSERT that committed
    # "successfully" into a project directory that no longer existed.
    #
    # Two seconds of short sleeps, because an open is not the capture hot path — nothing is
    # proxied yet, no flow is waiting on this fiber, and the surfaces that call it (a project
    # switch, `gori mcp` binding a project, a delete's dry-run count) can all afford a pause that
    # a typical compact finishes inside of. Bounded rather than blocking, so a pathological VACUUM
    # ends in a sentence the operator can act on rather than a hang with no output.
    CONTENTION_BUDGET = 2.seconds
    RETRY_DELAY       = 5.milliseconds

    def self.path(db_path : String) : String
      "#{Paths.canonical_file(db_path)}#{SUFFIX}"
    end

    # Is this a real file path we can lock at all? `:memory:` and the empty path are not.
    private def self.lockable?(db_path : String) : Bool
      !db_path.empty? && !db_path.starts_with?(':')
    end

    # Take the shared lock for `db_path`, or nil when there is nothing to take it on (an
    # in-memory database, an unwritable directory, a mount whose flock does not work). The
    # caller keeps it for as long as the database is open and `close`s it after.
    #
    # RAISES `Gori::Error` in exactly one case: an exclusive holder still there after
    # CONTENTION_BUDGET. `Store.open` lets that propagate on purpose — see the raise below.
    def self.try_shared(db_path : String) : OpenLock?
      return nil unless lockable?(db_path)
      lock_path = path(db_path)
      return nil unless Dir.exists?(File.dirname(lock_path))
      # `File.open` under its OWN rescue, not one that also covers the flock loop below: an
      # unwritable directory or a lock file owned by a teammate raises `File::Error` here, and
      # that is neither `DB::Error` nor `Gori::Error`, so it would sail past every rescue on the
      # open paths (`gori mcp` dies before the handshake, `gori run capture` backtraces) — the
      # opposite of what this class promises. Separate from the loop's rescues because the loop
      # has one failure it deliberately does NOT swallow.
      file = begin
        File.open(lock_path, "a") # never "w": truncating races a peer's own open
      rescue
        return nil # best effort — a store must open regardless
      end
      deadline = Time.instant + CONTENTION_BUDGET
      loop do
        begin
          file.flock_shared(blocking: false)
          return new(file)
        rescue ex : IO::Error
          # Contention is the only failure worth waiting out, and `flock_shared` reports every
          # failure as one `IO::Error`, so the errno is what separates them (see `contention?`).
          # Anything else is not going to change in two seconds — degrade to no lock, which is
          # what a read-only or network mount has always got.
          unless contention?(ex)
            file.close rescue nil
            return nil
          end
        rescue
          file.close rescue nil
          return nil
        end
        break if Time.instant >= deadline
        sleep RETRY_DELAY
      end
      # Still exclusively held after the whole budget. Returning nil here is what the bug was:
      # from that point the database is open with nothing announcing it, and the only holder of
      # an exclusive lock is a destructive operation — so "open anyway" means opening a database
      # that is being VACUUMed or rm_rf'd, invisibly to the process doing it. So refuse, and
      # refuse with a sentence naming the path.
      #
      # `db_path` as the CALLER spelled it, not `lock_path`'s canonicalized form:
      # `Project#open_failure_reason` passes a message through verbatim only when it
      # `includes?` the project's own `db_path`, so a canonicalized path would make the TUI
      # picker drop this reason for its generic "could not open '<name>'" wrapper on any
      # `$GORI_HOME` reached through a symlink.
      #
      # Logged too, because the surfaces that catch this show one line and no backtrace.
      # gori.log, not STDERR (#411).
      file.close rescue nil
      ::Log.warn { "open-lock: #{db_path} is held by a destructive operation; refusing to open it unannounced" }
      raise Gori::Error.new("cannot open #{db_path}: another gori instance is compacting or " \
                            "deleting this project — try again in a moment")
    end

    # Was this flock failure "somebody holds it" rather than "flock does not work here"?
    #
    # Crystal raises one `IO::Error` for both: `crystal/system/unix/file_descriptor.cr` turns
    # EAGAIN/EWOULDBLOCK from a non-blocking acquire into its "file is already locked" error and
    # re-raises every other errno verbatim. So the errno is the only discriminator, and it is the
    # stdlib's own spelling of the pair (`errno.in?(Errno::EAGAIN, Errno::EWOULDBLOCK)`, same
    # file) rather than a guess about which of the two a platform uses.
    #
    # A missing `os_error` reads as NOT contention: that direction costs one store opening
    # unannounced, the other direction costs a project nobody can open at all.
    private def self.contention?(ex : IO::Error) : Bool
      err = ex.os_error
      !err.nil? && err.in?(Errno::EAGAIN, Errno::EWOULDBLOCK)
    end

    # Take the EXCLUSIVE lock and HOLD it, for a caller about to do something destructive to the
    # database. nil means a live process has it open — refuse. Non-nil is the guard to keep for
    # the duration and `close` after; it may hold no file at all (nothing was lockable), because
    # "could not lock" must degrade to proceeding, not to a project nobody can ever delete.
    #
    # Held across the destructive act rather than probed and released, so a peer cannot open the
    # database in the gap between the answer and the `rm_rf`.
    def self.try_exclusive(db_path : String) : OpenLock?
      return new(nil) unless lockable?(db_path)
      lock_path = path(db_path)
      return new(nil) unless File.exists?(lock_path) # nobody ever opened it here
      file = begin
        File.open(lock_path, "a")
      rescue
        return new(nil) # cannot tell — do not invent a refusal
      end
      begin
        file.flock_exclusive(blocking: false)
        new(file)
      rescue IO::Error
        file.close rescue nil
        nil # contended — somebody has it open
      rescue
        file.close rescue nil
        new(nil)
      end
    end

    # Does any live process hold this database open? One definition of contention, shared with
    # `try_exclusive`, for a caller that only wants to REPORT (a delete's dry run) rather than act.
    def self.in_use?(db_path : String) : Bool
      guard = try_exclusive(db_path)
      return true unless guard
      guard.close
      false
    end

    def initialize(@file : File?)
    end

    def close : Nil
      if file = @file
        file.flock_unlock rescue nil
        file.close rescue nil
      end
    end
  end
end
