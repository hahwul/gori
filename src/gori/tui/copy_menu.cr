module Gori::Tui
  # Pure helpers that turn an HTTP message into the "copy as X" option set the
  # CopyPicker overlay shows — split a request into url/headers/body/cookies/curl,
  # a response into status+headers/body/raw. No TUI/state deps (Screen/Theme), so
  # the parsing is unit-testable on its own; the Runner wraps the result in a
  # CopyPicker and the controllers feed it the focused pane's bytes.
  module CopyMenu
    # One offered copy format: the row `label`, its mnemonic `key` (unique within a
    # single option list — the picker dispatches on it), and the `text` placed on
    # the clipboard when chosen.
    record Option, label : String, key : Char, text : String

    # Options for a REQUEST pane. `wire` is the request as it'd be sent (CRLF-framed,
    # env-expanded — the bytes replay uses), `target` the "scheme://host[:port]" base
    # that resolves an origin-form request line ("GET /p HTTP/1.1") into a full URL.
    # Empty formats (no body, no Cookie header) drop out so every row is meaningful.
    def self.request_options(wire : String, target : String) : Array(Option)
      head, body = split_message(wire)
      lines = head.split(/\r?\n/)
      request_line = lines.first? || ""
      header_lines = lines.size > 1 ? lines[1..] : [] of String
      method, req_target, _ = parse_request_line(request_line)
      url = resolve_url(req_target, target, header_lines)

      opts = [] of Option
      opts << Option.new("URL", 'u', url) unless url.empty?
      headers_text = header_lines.reject(&.strip.empty?).join("\n")
      opts << Option.new("Headers", 'h', headers_text) unless headers_text.empty?
      opts << Option.new("Body", 'b', body) unless body.empty?
      if cookie = cookie_value(header_lines)
        opts << Option.new("Cookies", 'c', cookie)
      end
      opts << Option.new("cURL", 'l', curl_command(method, url, header_lines, body)) unless url.empty?
      opts << Option.new("Raw request", 'r', wire) unless wire.strip.empty?
      opts
    end

    # Options for a RESPONSE pane, built from the raw head bytes (with or without a
    # trailing blank line) and body. "Raw response" re-joins them with a single CRLF
    # separator so a doubled/absent separator in `head` never leaks through — and is
    # offered ONLY when both parts are present, since with just one it would be a
    # byte-identical duplicate of the Status+headers (empty body) or Body (empty head) row.
    def self.response_options(head : String, body : String) : Array(Option)
      head_clean = head.sub(/\r?\n\r?\n\z/, "")
      opts = [] of Option
      opts << Option.new("Status + headers", 'h', head_clean) unless head_clean.strip.empty?
      opts << Option.new("Body", 'b', body) unless body.empty?
      unless body.empty? || head_clean.strip.empty?
        opts << Option.new("Raw response", 'r', "#{head_clean}\r\n\r\n#{body}")
      end
      opts
    end

    # Split an HTTP message into {head, body} on the first blank line — CRLF wire
    # form first, bare-LF (an editor snapshot) as a fallback.
    def self.split_message(text : String) : {String, String}
      if idx = text.index("\r\n\r\n")
        {text[0, idx], text[(idx + 4)..]}
      elsif idx = text.index("\n\n")
        {text[0, idx], text[(idx + 2)..]}
      else
        {text, ""}
      end
    end

    # {method, request-target, version} from a request line, best-effort (missing
    # tokens come back empty rather than raising on a hand-typed partial request).
    private def self.parse_request_line(line : String) : {String, String, String}
      parts = line.strip.split(' ')
      {parts[0]? || "", parts[1]? || "", parts[2]? || ""}
    end

    # The full URL for the request: an absolute-form request target as-is, else the
    # target base joined with the origin-form path (falling back to the Host header
    # when no target base is set — a hand-authored request). "" when unresolvable.
    private def self.resolve_url(req_target : String, target : String, header_lines : Array(String)) : String
      return req_target if req_target.starts_with?("http://") || req_target.starts_with?("https://")
      base = authority_base(target.strip)
      if base.empty?
        host = header_value(header_lines, "host")
        base = host ? "http://#{host}" : ""
      end
      return "" if base.empty?
      base = base.rstrip('/')
      return base if req_target.empty? || req_target == "*"
      req_target.starts_with?('/') ? "#{base}#{req_target}" : "#{base}/#{req_target}"
    end

    # scheme://host[:port] with any path/query the user may have pasted into the target
    # field stripped — the send path (FlowRequest.parse_target) uses only scheme/host/port,
    # so the copied URL must too, else it doubles the request-line path onto the target's.
    private def self.authority_base(target : String) : String
      sep = target.index("://")
      return target unless sep
      slash = target.index('/', sep + 3)
      slash ? target[0, slash] : target
    end

    # The combined Cookie header value(s), or nil when the request carries none.
    # Multiple Cookie lines are joined with "; " (the wire pair-separator).
    private def self.cookie_value(header_lines : Array(String)) : String?
      cookies = [] of String
      each_header(header_lines) { |name, value| cookies << value if name.downcase == "cookie" }
      cookies.empty? ? nil : cookies.join("; ")
    end

    # The first matching header's value (case-insensitive name), or nil.
    private def self.header_value(header_lines : Array(String), name : String) : String?
      want = name.downcase
      each_header(header_lines) { |hname, value| return value if hname.downcase == want }
      nil
    end

    # Yield each well-formed header line as {stripped name, stripped value}; lines
    # without a colon (blank/continuation) are skipped. ONE parse convention shared by
    # cookie_value / header_value / curl_command so they can't drift.
    private def self.each_header(header_lines : Array(String), & : String, String ->) : Nil
      header_lines.each do |line|
        name, sep, value = line.partition(":")
        next if sep.empty?
        n = name.strip
        next if n.empty?
        yield n, value.strip
      end
    end

    # A copy-pasteable `curl` invocation reproducing the request. URL first (browser
    # "Copy as cURL" convention), then -X for the method, each header as -H (dropping
    # Host/Content-Length — curl derives those), then --data-raw for a body. Every
    # argument is single-quoted with embedded quotes escaped, so it survives a paste
    # into any POSIX shell verbatim. Continuation lines keep it readable.
    private def self.curl_command(method : String, url : String, header_lines : Array(String), body : String) : String
      parts = ["curl #{shell_quote(url)}"]
      # Emit -X unless it's a plain bodyless GET (curl's default). A GET *with* a body
      # still needs -X GET, else curl silently promotes the request to POST.
      parts << "-X #{method}" unless method.empty? || (method == "GET" && body.empty?)
      each_header(header_lines) do |name, value|
        down = name.downcase
        next if down == "host" || down == "content-length"
        parts << "-H #{shell_quote("#{name}: #{value}")}"
      end
      parts << "--data-raw #{shell_quote(body)}" unless body.empty?
      parts.join(" \\\n  ")
    end

    # POSIX single-quote: wrap in '…' and rewrite each embedded ' as '\'' so the
    # result is one safe shell word regardless of what's inside (incl. newlines).
    private def self.shell_quote(s : String) : String
      "'" + s.gsub("'", "'\\''") + "'"
    end
  end
end
