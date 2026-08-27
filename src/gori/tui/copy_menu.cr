require "../export/curl"
require "../export/python_requests"
require "../export/js_fetch"
require "../export/go_http"
require "../export/httpie"
require "../export/csrf_poc"

module Gori::Tui
  # Pure helpers that turn an HTTP message into the "copy as X" option set the
  # CopyPicker overlay shows — split a request into url/headers/body/cookies/curl
  # (plus wscat for WebSocket Repeater), a response into status+headers/body/raw. No
  # TUI/state deps (Screen/Theme), so
  # the parsing is unit-testable on its own; the Runner wraps the result in a
  # CopyPicker and the controllers feed it the focused pane's bytes.
  #
  # The request PARSING and the curl serializer itself live in surface-neutral
  # `Gori::Export::Curl` — `gori run show --format curl` emits the same command, and the one
  # way for a CLI to do that without importing `Tui::` (which the layering contract forbids
  # for core, and which nothing else in `cli/` does) is for the bytes-to-shell-command rule
  # to have a home outside this file. What stays here is the MENU: which rows to offer, in
  # what order, under which mnemonic.
  module CopyMenu
    # One offered copy format: the row `label`, its mnemonic `key` (unique within a
    # single option list — the picker dispatches on it), and the `text` placed on
    # the clipboard when chosen.
    record Option, label : String, key : Char, text : String

    # Options for a REQUEST pane. `wire` is the request as it'd be sent (CRLF-framed,
    # env-expanded — the bytes repeater uses), `target` the "scheme://host[:port]" base
    # that resolves an origin-form request line ("GET /p HTTP/1.1") into a full URL.
    # Empty formats (no body, no Cookie header) drop out so every row is meaningful.
    def self.request_options(wire : String, target : String, *,
                             websocket_messages : Array(String)? = nil) : Array(Option)
      head, body = split_message(wire)
      lines = split_lines(head)
      request_line = lines.first? || ""
      header_lines = lines.size > 1 ? lines[1..] : [] of String
      method, req_target, version = Export::Curl.parse_request_line(request_line)
      url = Export::Curl.resolve_url(req_target, target, header_lines)

      opts = [] of Option
      opts << Option.new("URL", 'u', url) unless url.empty?
      headers_text = header_lines.reject(&.strip.empty?).join("\n")
      opts << Option.new("Headers", 'h', headers_text) unless headers_text.empty?
      opts << Option.new("Body", 'b', body) unless body.empty?
      if cookie = cookie_value(header_lines)
        opts << Option.new("Cookies", 'c', cookie)
      end
      unless url.empty?
        opts << Option.new("cURL", 'l', Export::Curl.command(method, url, header_lines, body, version))
        # "Copy as <language>" — the same request, serialized for the four common HTTP clients,
        # each a surface-neutral `Export::*` module (`gori run show --format python|fetch|go|httpie`
        # emits byte-identical text). Keys avoid 'p'/'s': the detail and single-flow list menus
        # append a "Req + Res pair" ('p') and a "Raw response" ('s') AFTER this list, and the
        # CopyPicker dispatches on the FIRST row whose key matches. `parts` re-parses `wire` the
        # one way the serializers do, so the menu cannot disagree with the CLI about the bytes.
        if parts = Export::RequestParts.from_wire(wire, target)
          opts << Option.new("Python", 'y', Export::PythonRequests.script(parts))
          opts << Option.new("fetch", 'f', Export::JsFetch.code(parts))
          opts << Option.new("Go", 'g', Export::GoHttp.program(parts))
          opts << Option.new("httpie", 'i', Export::Httpie.command(parts))
          opts << Option.new("CSRF PoC", 'x', Export::CsrfPoc.document(parts))
        end
      end
      if messages = websocket_messages
        ws_url = websocket_url(url)
        opts << Option.new("wscat", 'w', wscat_command(ws_url, header_lines, messages)) unless ws_url.empty?
      end
      opts << Option.new("Raw request", 'r', wire) unless wire.strip.empty?
      opts
    end

    # Just the cURL line for one request — what History's multi-flow "Copy as… cURL" needs
    # (#442). request_options above would allocate the Headers join, the Body and the whole Raw
    # request alongside it, i.e. several extra copies of a multi-MiB body per flow, only for the
    # caller to discard all but this one; and picking it out by its 'l' key would silently yield
    # nothing if the option list were ever renumbered. nil when there is no resolvable URL,
    # matching request_options dropping the row in that case.
    def self.curl_text(wire : String, target : String) : String?
      Export::Curl.text(wire, target)
    end

    # Options for a RESPONSE pane, built from the raw head bytes (with or without a
    # trailing blank line) and body. "Raw response" re-joins them with a single CRLF
    # separator so a doubled/absent separator in `head` never leaks through — and is
    # offered ONLY when both parts are present, since with just one it would be a
    # byte-identical duplicate of the Status+headers (empty body) or Body (empty head) row.
    def self.response_options(head : String, body : String) : Array(Option)
      head_clean = chomp_blank_line(head)
      opts = [] of Option
      opts << Option.new("Status + headers", 'h', head_clean) unless head_clean.strip.empty?
      opts << Option.new("Body", 'b', body) unless body.empty?
      unless body.empty? || head_clean.strip.empty?
        opts << Option.new("Raw response", 'r', "#{head_clean}\r\n\r\n#{body}")
      end
      opts
    end

    # Split an HTTP message into {head, body} on the first blank line. Kept as a name on
    # CopyMenu (the controllers and the copy specs call it) over the one implementation in
    # `Export::Curl`.
    def self.split_message(text : String) : {String, String}
      Export::Curl.split_message(text)
    end

    # `head` split into lines on LF, each with one trailing CR dropped — byte-wise, because a
    # captured head is not guaranteed to be valid UTF-8 and a Regexp over those bytes raises.
    # See `Export::Curl.split_lines`, the one implementation.
    private def self.split_lines(head : String) : Array(String)
      Export::Curl.split_lines(head)
    end

    # `head` without ONE trailing blank line — what `sub(/\r?\n\r?\n\z/, "")` spelled, byte-wise
    # for the same reason `split_lines` is. Longest suffix first, so a CRLF pair is taken
    # whole rather than leaving a stray CR behind. Response-side only, so it stays here.
    private def self.chomp_blank_line(head : String) : String
      bytes = head.to_slice
      {"\r\n\r\n", "\r\n\n", "\n\r\n", "\n\n"}.each do |suffix|
        s = suffix.to_slice
        next unless bytes.size >= s.size && bytes[bytes.size - s.size, s.size] == s
        return String.new(bytes[0, bytes.size - s.size])
      end
      head
    end

    # The combined Cookie header value(s), or nil when the request carries none.
    # Multiple Cookie lines are joined with "; " (the wire pair-separator).
    private def self.cookie_value(header_lines : Array(String)) : String?
      cookies = [] of String
      Export::Curl.each_header(header_lines) { |name, value| cookies << value if name.downcase == "cookie" }
      cookies.empty? ? nil : cookies.join("; ")
    end

    # A copy-pasteable wscat invocation for a WebSocket Repeater. wscat owns the
    # RFC 6455 upgrade headers and generates a fresh Sec-WebSocket-Key, so those
    # are deliberately omitted. Host, Origin and subprotocol have dedicated
    # options; all remaining application headers use repeatable -H. Repeater's
    # outbound text frames become repeatable -x commands and -w -1 keeps the
    # socket open after sending so subsequent server events remain visible.
    private def self.wscat_command(url : String, header_lines : Array(String),
                                   messages : Array(String)) : String
      parts = ["wscat -c #{Export::Curl.shell_quote(url)}"]
      if host = Export::Curl.header_value(header_lines, "host")
        parts << "--host #{Export::Curl.shell_quote(host)}"
      end
      if origin = Export::Curl.header_value(header_lines, "origin")
        parts << "-o #{Export::Curl.shell_quote(origin)}"
      end
      Export::Curl.each_header(header_lines) do |name, value|
        if name.downcase == "sec-websocket-protocol"
          value.split(',').each do |protocol|
            protocol = protocol.strip
            parts << "-s #{Export::Curl.shell_quote(protocol)}" unless protocol.empty?
          end
        end
      end
      Export::Curl.each_header(header_lines) do |name, value|
        case name.downcase
        when "host", "origin", "connection", "upgrade", "content-length",
             "sec-websocket-key", "sec-websocket-version", "sec-websocket-extensions",
             "sec-websocket-protocol"
          next
        else
          parts << "-H #{Export::Curl.shell_quote("#{name}: #{value}")}"
        end
      end
      messages.each { |message| parts << "-x #{Export::Curl.shell_quote(message)}" }
      parts << "-w -1" unless messages.empty?
      parts.join(" \\\n  ")
    end

    # CopyMenu resolves request lines as HTTP URLs because cURL is always offered.
    # wscat needs the equivalent WebSocket scheme; already-ws targets remain intact.
    private def self.websocket_url(url : String) : String
      return "ws://#{url[7..]}" if url.starts_with?("http://")
      return "wss://#{url[8..]}" if url.starts_with?("https://")
      return url if url.starts_with?("ws://") || url.starts_with?("wss://")
      ""
    end
  end
end
