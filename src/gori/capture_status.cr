require "json"
require "./bind_address"

module Gori
  # Per-project capture sidecar written by the session that holds the capture lock.
  # The project picker reads it (together with a flock probe) to show the live bind
  # address of a project opened in another gori instance. The file alone is NOT
  # authoritative — only a held `.capture.lock` means the project is live.
  class CaptureStatus
    STATUS_FILE = ".capture.status"

    record Status, host : String, port : Int32, listening : Bool

    def self.path(dir : String) : String
      File.join(dir, STATUS_FILE)
    end

    def self.write(dir : String, host : String, port : Int32, listening : Bool) : Nil
      Dir.mkdir_p(dir) unless Dir.exists?(dir)
      dest = path(dir)
      tmp = "#{dest}.tmp.#{Process.pid}"
      payload = {
        "host"      => host,
        "port"      => port,
        "listening" => listening,
      }.to_json
      begin
        File.write(tmp, payload)
        File.rename(tmp, dest)
      rescue ex
        File.delete?(tmp)
        raise ex
      end
    end

    def self.read(dir : String) : Status?
      parse_file(path(dir))
    end

    # Parse a status file; nil on missing, corrupt, or partial writes.
    private def self.parse_file(p : String) : Status?
      return nil unless File.exists?(p)
      json = JSON.parse(File.read(p))
      Status.new(
        host: json["host"].as_s,
        port: json["port"].as_i,
        listening: json["listening"].as_bool,
      )
    rescue
      nil
    end

    def self.clear(dir : String) : Nil
      File.delete?(path(dir))
    end

    # Human-friendly bind label for the picker. Terse: this rides inside a project row's
    # chip, so it takes the address without BindAddress's "(all interfaces)" note — the
    # address itself is identical to every other surface's.
    def self.format_endpoint(host : String, port : Int32) : String
      BindAddress.display(host, port, terse: true)
    end
  end
end
