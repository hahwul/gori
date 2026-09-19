# Shared harness for the spec/mcp/*_spec.cr files that drive `Gori::MCP::Server` end-to-end
# with scripted JSON-RPC lines over IO::Memory. Split out of the former spec/mcp_spec.cr; a
# helper used by one file only stayed private in that file. Names carry an `mcp_` prefix
# so they cannot shadow (or be shadowed by) the file-private helpers other specs keep.

require "compress/gzip"
require "socket"
require "digest/sha1"
require "base64"
require "openssl/hmac"

# Runs the server over the given request lines and returns each emitted line as a
# parsed JSON::Any (also proves STDOUT purity — a non-JSON line would raise here).
def mcp_drive(store, *lines, allow_actions = true, verify_upstream = true,
              project_name : String? = nil, project_slug : String? = nil) : Array(JSON::Any)
  input = IO::Memory.new(lines.join('\n') + "\n")
  output = IO::Memory.new
  Gori::MCP::Server.new(store,
    allow_actions: allow_actions, verify_upstream: verify_upstream,
    project_name: project_name, project_slug: project_slug,
    input: input, output: output).run
  output.to_s.each_line.reject(&.strip.empty?).map { |l| JSON.parse(l) }.to_a
end

# Parses the JSON payload a tools/call result carries in content[0].text.
def mcp_tool_payload(resp : JSON::Any) : JSON::Any
  JSON.parse(resp["result"]["content"][0]["text"].as_s)
end

def mcp_seed_flow(store, host, method, target, status = nil,
                  resp_head = "HTTP/1.1 200 OK\r\n\r\n", resp_body : Bytes? = nil,
                  content_type = nil) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: host, port: 443,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
  if status
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: status, head: resp_head.to_slice, body: resp_body, content_type: content_type))
  end
  id
end

# Minimal WebSocket origin for the MCP glue test: upgrade, echo one client frame,
# then close normally so send_websocket returns without waiting for its idle timer.
def start_mcp_ws_origin : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    next unless conn = origin.accept?
    conn.read_timeout = 5.seconds
    head = Gori::Proxy::Codec::Http1.read_head(conn).not_nil!
    key = String.new(head).each_line
      .find(&.downcase.starts_with?("sec-websocket-key:"))
      .try(&.split(':', 2).[1].strip) || ""
    accept = Base64.strict_encode(Digest::SHA1.digest(key + Gori::Repeater::WsEngine::GUID))
    conn << "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" \
            "Connection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
    conn.flush
    if (frame = Gori::Proxy::WS.read_frame(conn)) && frame.data?
      conn.write(Gori::Proxy::WS.encode(frame.opcode, frame.payload, mask: false))
    end
    conn.write(Gori::Proxy::WS.encode(Gori::Proxy::WS::OP_CLOSE, Bytes[0x03, 0xE8], mask: false))
    conn.flush
    conn.close
    origin.close
  rescue
    origin.close rescue nil
  end
  port
end

# Small CRUD gaps that used to be TUI-only: issue delete, scope-rule edit-in-place,
# sitemap tags, and repeater tags.
def mcp_ok_json(tools : Gori::MCP::Tools, name : String, args : String) : JSON::Any
  r = tools.call(name, JSON.parse(args))
  fail "tool #{name} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

def mcp_seed_flow(store, target = "/a") : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice))
  id
end

# A `codex` on PATH that is a shell script: it records the argv and the CODEX_HOME it was
# given, and exits with the code the caller asked for. The real CLI's contract is exactly
# that much — argv in, exit code and a sentence out — so a stand-in pins the half gori owns.
# Shared because both the CodexQueue spec (which reads the argv) and the Courier spec (which
# only needs a `codex` that succeeds) need the same stand-in, and a second copy would drift.
def mcp_with_fake_codex(exit_code : Int32 = 0, stderr : String = "", &)
  dir = File.tempname("gori-fake-codex")
  Dir.mkdir_p(dir)
  log = File.join(dir, "argv.txt")
  File.write(File.join(dir, "codex"), <<-SH)
    #!/bin/sh
    printf '%s\\n' "$@" > '#{log}'
    printf 'CODEX_HOME=%s\\n' "$CODEX_HOME" >> '#{log}'
    #{stderr.empty? ? "" : "echo #{stderr.inspect} >&2"}
    exit #{exit_code}
    SH
  File.chmod(File.join(dir, "codex"), 0o755)
  # `ENV["PATH"]?`, not `ENV["PATH"]`: a PATH-less environment must be restored to PATH-less
  # rather than to the empty string, which is a search path (the cwd) and not "no path".
  saved = ENV["PATH"]?
  ENV["PATH"] = "#{dir}:#{saved}"
  begin
    yield log
  ensure
    saved ? (ENV["PATH"] = saved) : ENV.delete("PATH")
    FileUtils.rm_rf(dir)
  end
end
