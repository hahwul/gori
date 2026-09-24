require "json"
require "./bind_address"
require "./durable_file"
require "./paths"

module Gori
  # Per-project capture sidecar written by the session that holds the capture lock.
  # The project picker reads it (together with a flock probe) to show the live bind
  # address of a project opened in another gori instance. The file alone is NOT
  # authoritative — only a held `.capture.lock` means the project is live.
  class CaptureStatus
    STATUS_FILE = ".capture.status"

    # `ca_cert_path` is the root CA the capturing session signs with — absent from a marker an
    # older gori wrote. It is here because the CA is chosen per PROCESS (`gori --ca-dir DIR`),
    # so another process pointing a client at this capture (`gori run shell`) cannot derive it
    # from the project: the default CA dir would name a CA this session never presents.
    record Status, host : String, port : Int32, listening : Bool, ca_cert_path : String? = nil

    # The legacy per-DIRECTORY marker path (`<dir>/.capture.status`), which the canonical
    # registry db keeps — see Project#capture_status_path for why anything else does not.
    #
    # `path` and `read` take a DIRECTORY because the project picker legitimately has only that:
    # it lists registry projects, whose marker is at the legacy path by definition. The WRITERS
    # are `_at`-only on purpose — a directory-keyed write is the defect this file's history is
    # about (two `--db` databases in one directory sharing one marker), so there is no
    # directory-keyed writer left for a new caller to reach for.
    def self.path(dir : String) : String
      File.join(dir, STATUS_FILE)
    end

    # Write the marker at an explicit PATH. The path-taking trio (`write_at`/`read_at`/
    # `clear_at`) exists for the same reason `CaptureLock.try_at` does: this marker is the
    # companion of a capture lock, and the lock is keyed on the DB FILE, so the marker has to
    # be too or the pair disagrees about which capture it describes. Two `--db` databases in
    # one directory each hold their OWN lock — deliberately, they are separate databases with
    # separate capture sessions — and both used to write this ONE directory-keyed file: the
    # second one's bind address overwrote the first's, and the first to close DELETED the
    # marker of a session still capturing. The picker then showed a live project on the wrong
    # port, or live with no address at all.
    def self.write_at(marker : String, host : String, port : Int32, listening : Bool,
                      ca_cert_path : String? = nil) : Nil
      # `Paths.ensure_dir`, not a bare `Dir.mkdir_p`: this can be the call that creates a
      # project directory, and every gori dir is owner-only 0700 (see Paths::DIR_MODE) —
      # the captured traffic DB lands in here. A plain mkdir_p leaves it at the umask,
      # world-traversable on a shared host.
      #
      # `tighten: false` because this directory is not always gori's. `Project#dir` is
      # `File.dirname(db_path)`, so a `--db /shared/team/traffic.db` project borrows an
      # arbitrary parent (project.cr says so); chmod'ing THAT to 0700 would strip group
      # access from a directory gori merely found. A dir gori creates still lands at 0700.
      Paths.ensure_dir(File.dirname(marker), tighten: false)
      payload = JSON.build do |j|
        j.object do
          j.field "host", host
          j.field "port", port
          j.field "listening", listening
          # Absolute: the reader is another process, with its own working directory.
          j.field "ca", File.expand_path(ca_cert_path) if ca_cert_path
        end
      end
      # 0644 is the fallback for a file that does not exist yet; this marker holds a bind
      # address, not a secret, and the 0700 dir above is what keeps it private.
      DurableFile.write(marker, payload, perm: File::Permissions.new(0o644))
    end

    def self.read(dir : String) : Status?
      parse_file(path(dir))
    end

    def self.read_at(marker : String) : Status?
      parse_file(marker)
    end

    # Parse a status file; nil on missing, corrupt, or partial writes.
    private def self.parse_file(p : String) : Status?
      return nil unless File.exists?(p)
      json = JSON.parse(File.read(p))
      Status.new(
        host: json["host"].as_s,
        port: json["port"].as_i,
        listening: json["listening"].as_bool,
        ca_cert_path: json["ca"]?.try(&.as_s?).try(&.presence),
      )
    rescue
      nil
    end

    def self.clear_at(marker : String) : Nil
      File.delete?(marker)
    end

    # Human-friendly bind label for the picker. Terse: this rides inside a project row's
    # chip, so it takes the address without BindAddress's "(all interfaces)" note — the
    # address itself is identical to every other surface's.
    def self.format_endpoint(host : String, port : Int32) : String
      BindAddress.display(host, port, terse: true)
    end
  end
end
