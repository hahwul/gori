require "socket"
require "json"

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
      list = [] of String
      ENV["CLAUDE_CODE_MESSAGING_SOCKET"]?.try { |p| list << p unless p.empty? }
      list << "/tmp/cc-socks/#{pid}.sock"
      uid = LibC.getuid
      list << "/tmp/cc-socks-#{uid}/#{pid}.sock"
      list
    end

    # The first candidate that exists as a socket, or nil when this process's parent is not a
    # Claude Code session (any other MCP client, or a launcher between the two).
    def self.discover(pid : Int64 = Process.ppid.to_i64) : String?
      candidates(pid).find { |p| File.info?(p).try(&.type.socket?) || false }
    end

    # The operator's line, framed. Kept short and honest: who is speaking, and that gori is
    # only the relay. Context (the tab, the marked flows) travels in `operator_messages`, not
    # here — a socket line is a sentence, not a payload.
    def self.frame(text : String, from_tab : String?) : String
      where = from_tab ? " (from the #{from_tab} tab)" : ""
      "[gori] The operator at the gori TUI says#{where}: #{text}"
    end

    # Write one message. `nil` on success, else the reason the operator should read. Never
    # raises: a courier runs this beside a live JSON-RPC session and one refused line must not
    # end it. Bounded: connect + write + close inside `timeout`.
    def self.deliver(path : String, text : String, *, token : String? = ENV["CLAUDE_CODE_MESSAGING_TOKEN"]?,
                     timeout : Time::Span = 3.seconds) : String?
      sock = UNIXSocket.new(path)
      sock.write_timeout = timeout
      begin
        if token && !token.empty?
          sock.puts({type: "auth", token: token}.to_json)
        end
        sock.puts({type: "user", message: {role: "user", content: text}}.to_json)
        sock.flush
      ensure
        sock.close rescue nil
      end
      nil
    rescue ex : Socket::ConnectError
      "session not accepting messages (#{ex.message})"
    rescue IO::TimeoutError
      "session did not read the message in #{timeout.total_seconds.to_i}s"
    rescue ex : IO::Error | Socket::Error
      "socket write failed: #{ex.message}"
    end
  end
end
