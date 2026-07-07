require "json"

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

    # Human-friendly bind label for the picker (127.0.0.1 → localhost).
    def self.format_endpoint(host : String, port : Int32) : String
      display_host = case host
                     when "127.0.0.1", "::1" then "localhost"
                     else                         host
                     end
      "#{display_host}:#{port}"
    end
  end
end
