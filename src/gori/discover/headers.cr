require "../proxy/codec/http1"

module Gori::Discover
  # Custom request-header handling shared by every Discover surface (the TUI config
  # overlay + editor, the CLI `-H` flag, the MCP `headers` map, and the History
  # "reuse this flow's headers" prefill).
  #
  # Discover sends a fixed GET per URL, so the Sender builds ONE merged header block
  # at construction. `Host` and `Connection` are always emitted by the Sender itself
  # — Host must match each crawled origin (a crawl spans several in-scope hosts) and
  # every send opens a fresh connection (`Connection: close`) — so they are never
  # taken from user input. `Accept` and `User-Agent` are defaults the user MAY
  # override; anything else the user supplies is appended.
  module Headers
    # Emitted defaults, in wire order; overridable by name (case-insensitive).
    DEFAULTS = [{"Accept", "*/*"}, {"User-Agent", "gori-discover"}]

    # Never taken from user/flow input — the Sender emits its own.
    FORCED = Set{"host", "connection"}

    # Framing / hop-by-hop headers dropped when reusing a captured flow's headers:
    # they describe that flow's body/transport, not a fresh discovery GET.
    DROP = Set{
      "host", "connection", "content-length", "content-type",
      "transfer-encoding", "te", "upgrade", "proxy-connection",
      "expect", "keep-alive",
    }

    # Parse raw "Name: Value" lines (CLI `-H`, the TUI editor) into pairs, dropping
    # anything malformed or unsafe: a value may not contain CR/LF (header injection),
    # and a name must be a non-empty RFC 7230 token.
    def self.parse_lines(lines : Array(String)) : Array({String, String})
      out = [] of {String, String}
      lines.each do |line|
        name, sep, value = line.partition(':')
        next if sep.empty?
        name = name.strip
        value = value.strip
        next if name.empty? || !valid_name?(name)
        next if value.includes?('\r') || value.includes?('\n')
        out << {name, value}
      end
      out
    end

    # Headers reused from a captured History flow: parse the stored request head and
    # keep only headers that make sense on a fresh discovery GET (drop `DROP`).
    def self.from_flow(request_head : Bytes) : Array({String, String})
      req = Proxy::Codec::Http1.parse_request_head(request_head)
      out = [] of {String, String}
      req.headers.each do |h|
        next if DROP.includes?(h.name.downcase)
        next if h.value.includes?('\r') || h.value.includes?('\n')
        out << {h.name, h.value}
      end
      out
    end

    # The final ordered header list the Sender emits between `Host` and `Connection`:
    # the defaults, with a same-named user header replacing the default's VALUE in
    # place (keeping the default's casing, mirroring the CLI repeater merge), plus any
    # extra user headers appended in order. Forced headers are skipped.
    def self.merge(user : Array({String, String})) : Array({String, String})
      result = DEFAULTS.dup
      user.each do |name, value|
        next if FORCED.includes?(name.downcase)
        idx = result.index { |rn, _| rn.compare(name, case_insensitive: true) == 0 }
        if idx
          result[idx] = {result[idx][0], value}
        else
          result << {name, value}
        end
      end
      result
    end

    # RFC 7230 token: no whitespace, control chars, or separators.
    private def self.valid_name?(name : String) : Bool
      name.each_char do |c|
        return false if c.ascii_whitespace? || c.control?
        return false if ":/()<>@,;\\\"[]?={}".includes?(c)
      end
      true
    end
  end
end
