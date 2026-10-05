require "socket"
require "json"
require "./operator_note"

module Gori::MCP
  # Claude Code's session inbox socket, as seen from the `gori mcp` process it spawned (#1090).
  #
  # Every interactive or `-p` Claude Code session binds a Unix socket and accepts one JSON line
  # per connection: `{"type":"user","message":{"role":"user","content":"…"}}`. An idle session
  # starts a turn on it; a busy one reads it between tool calls. The CLI exports the path as
  # `CLAUDE_CODE_MESSAGING_SOCKET` to hooks and Bash — NOT to MCP servers — so this module finds
  # it the other way round: the socket is named by the Claude process's pid, and the Claude
  # process is this server's PARENT (`Process.ppid`; verified on every launch shape tried).
  #
  # The message arrives framed to the model as a note from another Claude session, which its
  # own prompt tells it is a request and not user consent. gori prefixes the text so the model
  # reads it as relayed operator intent; whether it acts is the model's call, and a delivery
  # here means "landed", never "done".
  module ClaudeInbox
    # Where the CLI puts the socket: `/tmp/cc-socks/<pid>.sock` on macOS as observed; the
    # documented fallback is a per-user directory. Both are tried, plus the env var when a
    # launcher passed it through.
    def self.candidates(pid : Int64 = Process.ppid.to_i64) : Array(String)
      list = ["/tmp/cc-socks/#{pid}.sock", "/tmp/cc-socks-#{uid}/#{pid}.sock"]
      # The env var is trusted only when it names THIS parent: a `gori mcp` under Codex, or
      # under a Claude session started from another Claude session's Bash tool, inherits the
      # OUTER session's socket path, and writing there would land the operator's line in a
      # session the picker never named.
      ENV["CLAUDE_CODE_MESSAGING_SOCKET"]?.try do |p|
        list << p if !p.empty? && File.basename(p) == "#{pid}.sock" && !list.includes?(p)
      end
      list
    end

    # The first candidate that is this user's socket, or nil when this process's parent is not
    # a Claude Code session (any other MCP client, or a launcher between the two).
    def self.discover(pid : Int64 = Process.ppid.to_i64, uid : String = self.uid) : String?
      candidates(pid).find { |p| ours?(p, uid) }
    end

    # This process's uid. Windows has none, and no Unix socket under `/tmp` for `ours?` to
    # accept, so there `discover` finds nothing and the courier keeps to polling.
    def self.uid : String
      {% if flag?(:win32) %}
        ""
      {% else %}
        LibC.getuid.to_s
      {% end %}
    end

    # A socket this user owns (not a symlink to one), in a directory only this user can change.
    # `/tmp` is shared: another local user who holds `/tmp/cc-socks`, or plants a symlink in it,
    # can take the operator's text and have it recorded as carried, so the real session never
    # sees it. The directory rule is what keeps the entry from being swapped between this look
    # and the connect; Claude Code makes it 0700 and the user's own.
    def self.ours?(path : String, uid : String) : Bool
      info = File.info?(path, follow_symlinks: false)
      dir = File.info?(File.dirname(path), follow_symlinks: false)
      return false unless info && dir && info.type.socket? && info.owner_id == uid && dir.owner_id == uid
      !dir.permissions.includes?(File::Permissions::GroupWrite) && !dir.permissions.includes?(File::Permissions::OtherWrite)
    end

    # The session token, only for the socket the env var names: Claude Code does not export
    # either to an MCP server, so a token in this environment was inherited from an OUTER
    # session and belongs to that session's socket, not the one `discover` found by pid.
    def self.token_for(path : String) : String?
      named = ENV["CLAUDE_CODE_MESSAGING_SOCKET"]?.presence || return
      ENV["CLAUDE_CODE_MESSAGING_TOKEN"]? if named == path || (File.same?(named, path) rescue false)
    end

    # Write one message. `nil` on success, else the reason the operator should read. Never
    # raises: a courier runs this beside a live JSON-RPC session and one refused line must not
    # end it. Bounded: connect + write + close inside `timeout`.
    def self.deliver(path : String, text : String, *, token : String? = token_for(path),
                     timeout : Time::Span = 3.seconds) : String?
      # `UNIXSocket.new(path)` has no connect timeout; a session whose accept backlog is full
      # would park the courier for good. Connect by hand, bounded — and inside the ensure, so
      # a refused connect does not leave the fd to the finalizer.
      sock = Socket.unix(Socket::Type::STREAM)
      begin
        begin
          sock.connect(Socket::UNIXAddress.new(path), timeout: timeout)
        rescue ex : Socket::Error
          # Any refusal, not only a `ConnectError`: Windows raises a plain `Socket::Error`
          # (WSAENETDOWN) for a path nothing listens on.
          return "session not accepting messages (#{ex.message})"
        end
        sock.write_timeout = timeout
        if token && !token.empty?
          sock.puts({type: "auth", token: token}.to_json)
        end
        sock.puts({type: "user", message: {role: "user", content: text}}.to_json)
        sock.flush
      ensure
        sock.close rescue nil
      end
      nil
    rescue IO::TimeoutError
      "session did not read the message in #{timeout.total_seconds.to_i}s"
    rescue ex : IO::Error | Socket::Error
      "socket write failed: #{ex.message}"
    end
  end
end
