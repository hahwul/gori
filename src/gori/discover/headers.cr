require "./url"
require "../env"
require "../proxy/codec/http1"

module Gori::Discover
  # Custom request-header handling shared by every Discover surface (the TUI config
  # overlay + editor, the CLI `-H` flag, the MCP `headers` map, and the History
  # "reuse this flow's headers" prefill).
  #
  # Discover sends a fixed GET per URL, so the Sender builds ONE merged header block
  # at construction. `Host` and `Connection` are owned by the Sender itself — Host must
  # match each crawled origin (a crawl spans several in-scope hosts), and `Connection`
  # is what decides whether the socket can be reused, so it follows the run's keep-alive
  # setting (`Connection: close` when off, omitted when on) rather than user input.
  # `Accept` and `User-Agent` are defaults the user MAY override; anything else the user
  # supplies is appended.
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
    #
    # Pass `rejected` to learn WHICH lines were dropped. Refusing a CR/LF-carrying value is
    # right — this is an automated crawler, not the repeater, and the value is spliced
    # straight into every probe's header block — but refusing it SILENTLY is not: the drop
    # took `Authorization` with it, so an authenticated sweep ran unauthenticated and reported
    # "found nothing" over the whole authenticated surface, with a clean exit and nothing on
    # stderr. An out-collector rather than a changed return type, so the three surfaces that
    # call this can adopt the report one at a time.
    def self.parse_lines(lines : Array(String),
                         rejected : Array(String)? = nil) : Array({String, String})
      out = [] of {String, String}
      lines.each do |line|
        # A BLANK line is not a header anyone asked for — the TUI overlay parses an editor
        # buffer, which is full of them — so it is neither parsed nor reported. Everything
        # else the operator typed is one or the other, never silently neither.
        next if line.blank?
        name, sep, value = line.partition(':')
        name = name.strip
        value = value.strip
        if sep.empty? || name.empty? || !Proxy::Codec::Http1.header_name_safe?(name) || !safe_value?(value)
          rejected.try(&.<<(line))
          next
        end
        out << {name, value}
      end
      out
    end

    # The NAMES of already-parsed headers whose value stops being safe once `$VAR` is
    # resolved — the realistic half of the same failure: the header the operator typed is
    # fine, and `TOKEN` holds a value read from a file with a trailing newline in it.
    #
    # A QUERY, so a surface can refuse the run BEFORE any traffic. `expand` (below) still
    # drops such a value at send time, and must: it is the last line before the wire and a
    # binding can resolve later than plan-build. But a backstop that fires silently on every
    # probe is not a report, and by then the crawl is already running.
    def self.unsafe_expanded(pairs : Array({String, String})) : Array(String)
      pairs.compact_map { |(name, value)| safe_value?(Env.expand(value).strip) ? nil : name }
    end

    # Headers reused from a captured History flow: parse the stored request head and
    # keep only headers that make sense on a fresh discovery GET (drop `DROP`).
    def self.from_flow(request_head : Bytes) : Array({String, String})
      req = Proxy::Codec::Http1.parse_request_head(request_head)
      out = [] of {String, String}
      req.headers.each do |h|
        next if DROP.includes?(h.name.downcase)
        next unless safe_value?(h.value)
        out << {h.name, h.value}
      end
      out
    end

    # Header values with `$VAR` resolved, applied by `Discover::Plan` at send time (the
    # editor / CLI flag / MCP map all keep the raw `$TOKEN` so the operator still sees what
    # they typed). Expansion happens AFTER parsing, so `safe_value?` has to run again here:
    # `parse_lines` only ever judged the literal `$TOKEN`, and an env var whose VALUE carries
    # a newline would otherwise splice extra headers into every probe the crawl sends.
    def self.expand(pairs : Array({String, String})) : Array({String, String})
      pairs.compact_map do |(name, value)|
        # Stripped AFTER substituting, matching what `parse_lines` did back when MCP expanded
        # before parsing: a var whose value has surrounding spaces must not widen the OWS.
        expanded = Env.expand(value).strip
        safe_value?(expanded) ? {name, expanded} : nil
      end
    end

    # The one injection rule: a value may not carry CR or LF. Applied wherever untrusted text
    # reaches a request line or header — hand-typed lines, a reused flow's headers, a crawl
    # seed (`Discover::Plan`), and post-expansion.
    def self.safe_value?(value : String) : Bool
      !value.includes?('\r') && !value.includes?('\n')
    end

    # The same rule for a URL bound for a request line. `URI.parse` keeps a raw CR/LF
    # VERBATIM in a URL's host, path and query alike (it validates none of the three), and
    # `Discover::Sender#build_get` splices all three into the request line and the `Host`
    # header — so any one of them can splice a second, fully attacker-chosen request onto
    # the connection. Checking only the path would leave the other two open.
    #
    # This is the FRAMING half of the octets a request line cannot carry, and the half whose
    # answer is refusal. `Codec::Http1.request_token_safe?` is the whole class and its one home
    # (every octet <= 0x20 plus DEL — SP and TAB separate the line's fields without starting a
    # second message); `Url.parse` percent-encodes the rest instead of dropping it, because a
    # space in an href is ordinary handwritten HTML (#394). Nothing that reaches this predicate
    # has a repair.
    def self.safe_url?(parts : Url::Parts) : Bool
      q = parts.query
      safe_value?(parts.host) && safe_value?(parts.path) && (q.nil? || safe_value?(q))
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
  end
end
