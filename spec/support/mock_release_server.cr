require "http/server"
require "json"

# Minimal GitHub-shaped release server for update download/progress specs.
# Serves /repos/hahwul/gori/releases/latest and /download/<asset>.
class MockReleaseServer
  getter base_url : String
  getter port : Int32
  getter tag : String
  getter body : Bytes
  getter asset_names : Array(String)

  @server : HTTP::Server
  @closed = false

  # `reported_size`: override the release JSON's `size` field independent of the
  # real asset body (defaults to the true body size). Lets specs simulate the
  # unauthenticated/wrong-JSON-size scenario (Bug A) without touching the real
  # HTTP Content-Length, which is always derived from the actual body.
  #
  # `truncate_at`: when set, the download handler writes only this many bytes
  # of `body` (Content-Length still advertises the full size), sets
  # `Connection: close`, and hangs up — simulating a server killed mid-transfer.
  def initialize(*,
                 tag : String = "v99.0.0",
                 body : String | Bytes = "mock-gori-binary\n",
                 asset_names : Array(String)? = nil,
                 throttle_bps : Int32 = 0,
                 reported_size : Int64? = nil,
                 truncate_at : Int32? = nil)
    @tag = tag
    @body = body.is_a?(Bytes) ? body : body.to_slice
    ver = tag.lchop('v').lchop('V')
    @asset_names = asset_names || [
      "gori-v#{ver}-linux-x86_64",
      "gori-v#{ver}-linux-arm64",
      "gori-v#{ver}-osx-arm64.tar.gz",
      "gori-v#{ver}-osx-x86_64.tar.gz",
    ]
    @throttle_bps = throttle_bps
    @reported_size = reported_size || @body.size.to_i64
    @truncate_at = truncate_at

    # Bind first so we know the ephemeral port before building asset URLs.
    @server = HTTP::Server.new do |context|
      handle(context)
    end
    @port = @server.bind_unused_port("127.0.0.1").port
    @base_url = "http://127.0.0.1:#{@port}"

    spawn { @server.listen }
    # Tiny settle so the accept loop is up before the first client call.
    sleep 10.milliseconds
  end

  def api_url : String
    "#{@base_url}/repos/hahwul/gori/releases/latest"
  end

  def download_url(name : String) : String
    "#{@base_url}/download/#{name}"
  end

  def release_json : String
    assets = @asset_names.map do |name|
      {
        "name"                 => name,
        "browser_download_url" => download_url(name),
        "size"                 => @reported_size,
      }
    end
    {
      "tag_name" => @tag,
      "assets"   => assets,
    }.to_json
  end

  def close : Nil
    return if @closed
    @closed = true
    @server.close
  rescue
  end

  private def handle(context : HTTP::Server::Context) : Nil
    req = context.request
    path = req.path
    case
    when path == "/repos/hahwul/gori/releases/latest"
      context.response.content_type = "application/json"
      context.response.print release_json
    when path.starts_with?("/download/")
      name = path.lchop("/download/")
      unless @asset_names.includes?(name)
        context.response.status = HTTP::Status::NOT_FOUND
        context.response.print "unknown asset"
        return
      end
      context.response.content_type = "application/octet-stream"
      context.response.content_length = @body.size
      if trunc = @truncate_at
        # Promise the full Content-Length but only ever send `trunc` bytes, then
        # force the socket closed — simulates a server/process killed mid-transfer.
        context.response.headers["Connection"] = "close"
        context.response.write(@body[0, Math.min(trunc, @body.size)])
        context.response.flush
        context.response.close
      elsif @throttle_bps > 0
        write_throttled(context.response, @body, @throttle_bps)
      else
        context.response.write(@body)
      end
    else
      context.response.status = HTTP::Status::NOT_FOUND
      context.response.print "not found"
    end
  end

  private def write_throttled(io : IO, data : Bytes, bps : Int32) : Nil
    # Rough byte-rate throttle so progress meters have time to redraw in tests/manual demos.
    chunk = Math.max(1024, bps // 20) # ~50ms worth per write at target rate
    offset = 0
    while offset < data.size
      n = Math.min(chunk, data.size - offset)
      io.write(data[offset, n])
      io.flush
      offset += n
      sleep (n.to_f / bps).seconds if offset < data.size
    end
  end
end

def with_mock_release_server(**kwargs, &)
  server = MockReleaseServer.new(**kwargs)
  begin
    yield server
  ensure
    server.close
  end
end
