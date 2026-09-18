require "json"
require "./paths"

module Gori
  # "A process is attached to this PROJECT" — a per-process marker file in a directory beside
  # the database, held for the session's lifetime with an EXCLUSIVE flock.
  #
  # Two kinds, one directory each. `gori mcp` announces an `mcp` marker under
  # `<canonical db_path>.agents/` while it has a store bound, and the TUI and the project
  # picker read that directory to show who is attached (#815). A gori TUI announces a `tui`
  # marker under `<canonical db_path>.windows/` for the length of one project visit, and
  # `get_current_context` reads THAT to tell an agent whether the selection it is relaying
  # belongs to a window still on screen (#1091).
  #
  # The same split as `CaptureLock` + `CaptureStatus`, collapsed into one file per holder:
  # the FLOCK is the truth about liveness (the kernel releases it when the process dies, even
  # on SIGKILL, where an `ensure`-based cleanup never runs), and the JSON body is decoration —
  # the client's name, its pid, when it attached. A marker whose lock nobody holds is a stale
  # leftover, and `live` sweeps it. A marker whose body cannot be parsed is still a live
  # attachment ("someone is here, name unknown"), because the lock says so.
  #
  # WHY NOT `OpenLock`: that lock is anonymous and shared — it answers "somebody has this
  # database open", and a second TUI, a `gori run` read, or a delete's dry-run count all hold
  # it too, so it can neither name the holder nor tell an agent from anything else. WHY NOT A
  # DB ROW: the picker never opens project databases (it stats files), a `--read-only` MCP
  # server cannot write one, and a heartbeat write would move `data_version` and make every
  # watching TUI reload rules/scope/bindings on each beat.
  #
  # Keyed on the CANONICALIZED db path (`Paths.canonical_file`, `OpenLock.path`'s rule) so a
  # `--db` spelling difference or a symlinked `$GORI_HOME` cannot give one database two marker
  # directories. Best effort throughout: announcing can fail (an unwritable `--db` parent, a
  # filesystem without flock) and the server must run anyway, so every failure degrades to
  # "no marker" with one warning line — never a raise.
  class AgentPresence
    # One directory PER KIND, and that split is load-bearing rather than tidiness (#1091).
    # `count` must stay parse-free for the project picker's render path, so a reader can only
    # tell an agent from a TUI window by WHERE its marker is; `parse_entry` falls back to the
    # directory's kind when a body will not parse, which a body-carried kind could not do; and
    # `Tools` announces its own `mcp` marker the moment it binds, so a reader that forgot to
    # filter would find this process and call it a live TUI forever. A directory makes all
    # three impossible instead of merely unlikely.
    DIR_SUFFIX     = ".agents"  # KIND_MCP — #815's directory, unchanged on disk
    TUI_DIR_SUFFIX = ".windows" # KIND_TUI — a gori TUI window attached to this project
    KIND_MCP       = "mcp"
    KIND_TUI       = "tui"

    # One live attachment, as read back from a marker. `client`/`client_version` come from the
    # MCP initialize handshake and can be absent (the client never introduced itself) or nil on
    # a body that would not parse; `path` is the marker file, which specs use to prove an
    # in-place update kept the inode.
    record Entry,
      kind : String,
      client : String?,
      client_version : String?,
      pid : Int64?,
      attached_at : Time?,
      read_only : Bool,
      selection_source : String?,
      path : String,
      # Whether the window holding this marker also holds the project's capture lock. Only a
      # `tui` marker reports it; nil on every `mcp` one, and on a body that would not parse.
      # A DEFAULT, because ~a dozen construction sites (specs included) predate the field.
      holds_capture : Bool? = nil

    # Exhaustive, and it RAISES on an unknown kind rather than defaulting. The split above is
    # load-bearing, and a ternary's else-branch quietly makes the mapping total: a typo or a
    # future third kind would land in `.agents`, where the picker's parse-free `count` folds
    # it into the `mcp×N` chip and the TUI filter never finds it. Callers pass constants, so
    # this is a compile-time-shaped mistake caught at the one place that can catch it —
    # `announce` rescues everything anyway, so the worst case is a missing marker.
    def self.dir_for(db_path : String, kind : String = KIND_MCP) : String
      suffix =
        case kind
        when KIND_MCP then DIR_SUFFIX
        when KIND_TUI then TUI_DIR_SUFFIX
        else               raise ArgumentError.new("agent-presence: unknown marker kind #{kind.inspect}")
        end
      "#{Paths.canonical_file(db_path)}#{suffix}"
    end

    # Is this a real file path we can put a marker directory next to? `:memory:` and the
    # empty path are not — same rule as `OpenLock.lockable?`.
    private def self.markable?(db_path : String) : Bool
      !db_path.empty? && !db_path.starts_with?(':')
    end

    # Create a marker for THIS process and hold its lock. nil when there is nothing to mark
    # (an in-memory database) or the marker could not be written (unwritable directory, a
    # mount whose flock does not work) — logged once, never raised: the caller is a server
    # whose session must not die over a presence decoration.
    #
    # The lock is taken on the TEMP file BEFORE it is renamed into place, so no reader can
    # ever see the final name unlocked — a reader that did would sweep a live marker as
    # stale. `File.rename` keeps the open-file-description, and flock rides on that, not on
    # the name.
    #
    # A SIGKILL in the sub-millisecond window between `File.open(tmp)` and `File.rename` leaks
    # the `.tmp` (readers skip dot-prefixed names, so it is never swept). That is an accepted
    # tradeoff, not an oversight: the alternative — sweeping unlocked `.tmp` files — would race
    # a live writer's own tmp in its open→flock gap and make its `rename` fail. The leak is
    # bounded (one death per announce window, and announce runs once per bind) and `registry
    # #delete`'s rm_rf clears the directory wholesale.
    def self.announce(db_path : String, *, client : String?, client_version : String?,
                      read_only : Bool, selection_source : String?,
                      kind : String = KIND_MCP,
                      holds_capture : Bool? = nil) : AgentPresence?
      return nil unless markable?(db_path)
      name = "#{Process.pid}-#{Random::Secure.hex(4)}.json"
      dir = dir_for(db_path, kind)
      tmp = File.join(dir, ".#{name}.tmp")
      file = nil
      begin
        # `tighten: false` for `CaptureLock.try_at`'s reason: a `--db` project borrows a
        # parent directory that is not gori's to chmod. A dir we create still lands at 0700.
        Paths.ensure_dir(dir, tighten: false)
        # 0644 like `CaptureStatus.write_at`: the body is not a secret, the 0700 project
        # directory above it is what keeps it private.
        file = File.open(tmp, "w", perm: File::Permissions.new(0o644))
        file.flock_exclusive(blocking: false) # a fresh temp file: nothing to contend with
        presence = new(file, File.join(dir, name), kind: kind, client: client,
          client_version: client_version, read_only: read_only,
          selection_source: selection_source, pid: Process.pid.to_i64,
          attached_at_ms: Time.utc.to_unix_ms, holds_capture: holds_capture)
        presence.write_payload
        File.rename(tmp, File.join(dir, name))
        presence
      rescue ex
        file.try { |f| f.close rescue nil }
        File.delete?(tmp) rescue nil
        ::Log.warn { "agent-presence: could not announce #{db_path}: #{ex.message}" }
        nil
      end
    end

    # All the live attachments for `db_path`, oldest first. Sweeps what it finds dead: a
    # marker whose lock CAN be taken has no living owner (flock died with its process), so
    # this is where SIGKILL'd servers get cleaned up. Never raises — the callers are a render
    # loop and a picker probe, and a filesystem hiccup must read as "nobody attached".
    def self.live(db_path : String, kind : String = KIND_MCP) : Array(Entry)
      entries = [] of Entry
      each_live(db_path, kind) { |path| entries << parse_entry(path, kind) }
      entries.sort_by { |e| e.attached_at.try(&.to_unix_ms) || Int64::MAX }
    rescue
      [] of Entry
    end

    # How many attachments are live, WITHOUT reading or parsing any marker body. The project
    # picker only needs the count for its `mcp×N` chip, and it probes every project every
    # render cadence — a File.read + JSON.parse per contended marker there is wasted work on
    # the render path. Sweeps dead markers exactly as `live` does (they share `each_live`).
    def self.count(db_path : String, kind : String = KIND_MCP) : Int32
      n = 0
      each_live(db_path, kind) { |_| n += 1 }
      n
    rescue
      0
    end

    # Walk the marker directory, sweeping any marker whose owner is gone (its flock is free),
    # and yield the path of each LIVE one. The shared core of `live` and `count`: liveness and
    # the stale sweep are decided here once, so the two callers cannot drift on either.
    private def self.each_live(db_path : String, kind : String, & : String ->) : Nil
      return unless markable?(db_path)
      dir = dir_for(db_path, kind)
      return unless Dir.exists?(dir)
      Dir.each_child(dir) do |child|
        # Dot-prefixed names are in-flight temp files (see `announce`) — not ours to judge
        # or sweep, their writer still has them.
        next if child.starts_with?('.')
        next unless child.ends_with?(".json")
        path = File.join(dir, child)
        probe = File.open(path, "r") rescue next # flock works on a read-only fd
        begin
          begin
            probe.flock_exclusive(blocking: false)
            # We got the lock ⇒ the owner is gone. Sweep it; a peer sweeping the same file
            # concurrently makes the second `delete?` a no-op.
            File.delete?(path) rescue nil
            next
          rescue ex : IO::Error
            # EAGAIN/EWOULDBLOCK is the one refusal that MEANS a live holder (same errno
            # discrimination as `OpenLock.contention?`); any other failure is "cannot tell",
            # which must neither sweep nor count.
            next unless contention?(ex)
          rescue
            next
          end
          yield path
        ensure
          probe.close rescue nil
        end
      end
    end

    # Was this flock failure "somebody holds it" rather than "flock does not work here"?
    # The stdlib raises one `IO::Error` for both; the errno separates them (`open_lock.cr`
    # spells out why these two values and why a missing os_error reads as NOT contention —
    # here that direction skips a sweep rather than inventing a live agent).
    private def self.contention?(ex : IO::Error) : Bool
      err = ex.os_error
      !err.nil? && err.in?(Errno::EAGAIN, Errno::EWOULDBLOCK)
    end

    private def self.parse_entry(path : String, kind : String) : Entry
      json = JSON.parse(File.read(path))
      Entry.new(
        # The DIRECTORY is what the kind falls back to, never KIND_MCP: a half-written `tui`
        # marker read as an agent would be a window this process then reports as absent.
        kind: json["kind"]?.try(&.as_s?) || kind,
        client: json["client"]?.try(&.as_s?),
        client_version: json["client_version"]?.try(&.as_s?),
        pid: json["pid"]?.try(&.as_i64?),
        attached_at: json["attached_at_ms"]?.try(&.as_i64?).try { |ms| Time.unix_ms(ms) },
        read_only: json["read_only"]?.try(&.as_bool?) || false,
        selection_source: json["selection_source"]?.try(&.as_s?),
        path: path,
        # `.as_bool?`, not a truthiness test: `false` ("this window is NOT the capture
        # holder") is exactly the answer this field exists to carry, and it must stay
        # distinguishable from an `mcp` marker, which never reports one at all.
        holds_capture: json["holds_capture"]?.try(&.as_bool?),
      )
    rescue
      # The LOCK said someone is here; a body that will not parse (a partial write, outside
      # interference) demotes the row to "attached, name unknown" — never to absent.
      Entry.new(kind: kind, client: nil, client_version: nil, pid: nil,
        attached_at: nil, read_only: false, selection_source: nil, path: path)
    end

    def initialize(@file : File, @path : String, *, @kind : String, @client : String?,
                   @client_version : String?, @read_only : Bool, @selection_source : String?,
                   @pid : Int64, @attached_at_ms : Int64, @holds_capture : Bool? = nil)
      @closed = false
    end

    # Fill in the client's name once the initialize handshake delivers it — IN PLACE, on the
    # locked fd. Never via `DurableFile.write`: its temp+rename would swap the inode and the
    # flock (which lives on the open-file-description of the OLD inode) would silently stop
    # guarding the file readers see.
    def update(client : String?, client_version : String?) : Nil
      return if @closed
      @client = client
      @client_version = client_version
      begin
        write_payload
      rescue ex
        ::Log.warn { "agent-presence: could not update marker: #{ex.message}" }
      end
    end

    # Follow the capture lock, which `c` moves between windows mid-session. IN PLACE on the
    # locked fd for `update`'s reason above, and a no-op when the bit has not moved — so an
    # idle project's poll writes nothing at all. This is NOT a heartbeat: liveness is the
    # flock, and there is deliberately nothing here for a reader to time out on.
    def update_capture(holds : Bool) : Nil
      return if @closed || @holds_capture == holds
      @holds_capture = holds
      begin
        write_payload
      rescue ex
        ::Log.warn { "agent-presence: could not update marker: #{ex.message}" }
      end
    end

    # Delete FIRST, then unlock: once the name is gone no reader can reach the inode, so
    # there is no window where a reader finds the file unlocked and "sweeps" it mid-close.
    # Idempotent — `release_presence` and a server's ensure may both get here.
    def close : Nil
      return if @closed
      @closed = true
      File.delete?(@path) rescue nil
      @file.flock_unlock rescue nil
      @file.close rescue nil
    end

    protected def write_payload : Nil
      @file.rewind
      @file.truncate(0)
      @file.print({
        kind:             @kind,
        client:           @client,
        client_version:   @client_version,
        pid:              @pid,
        attached_at_ms:   @attached_at_ms,
        read_only:        @read_only,
        selection_source: @selection_source,
        holds_capture:    @holds_capture,
      }.to_json)
      @file.flush
    end
  end
end
