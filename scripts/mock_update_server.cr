#!/usr/bin/env crystal
# Mock GitHub releases API + asset download for testing `gori update` progress.
#
#   crystal run scripts/mock_update_server.cr -- --port 8765 --size 4M --throttle 400k
#
# Then in another terminal:
#
#   GORI_UPDATE_API_URL=http://127.0.0.1:8765/repos/hahwul/gori/releases/latest \
#     ./bin/gori update
#
# Or exercise the library path without replacing your real binary:
#
#   crystal eval '
#     require "./src/gori"
#     io = STDOUT
#     json = HTTP::Client.get("http://127.0.0.1:8765/repos/hahwul/gori/releases/latest").body
#     target = File.tempname("gori-mock-")
#     File.write(target, "old"); File.chmod(target, 0o755)
#     Gori::Update.update_binary(target, io, force_progress: true, release_json: json)
#   '
#
# Flags:
#   --port N          listen port (default 8765)
#   --size N[kKmMgG]  asset body size (default 2M)
#   --throttle N[kKmM] max bytes/sec when streaming body (0 = full speed)
#   --tag TAG         release tag (default v99.0.0 so local 0.x always updates)
#   --body PATH       serve this file as the asset body instead of synthetic bytes

require "http/server"
require "json"
require "option_parser"

port = 8765
size_bytes = 2_i64 * 1024 * 1024
throttle_bps = 0
tag = "v99.0.0"
body_path : String? = nil

def parse_size(raw : String) : Int64
  s = raw.strip.downcase
  mult = 1_i64
  if s.ends_with?('g')
    mult = 1024_i64 ** 3
    s = s.rchop
  elsif s.ends_with?('m')
    mult = 1024_i64 ** 2
    s = s.rchop
  elsif s.ends_with?('k')
    mult = 1024_i64
    s = s.rchop
  end
  n = s.to_i64?
  raise "invalid size '#{raw}'" unless n && n >= 0
  n * mult
end

OptionParser.parse do |p|
  p.banner = "Usage: crystal run scripts/mock_update_server.cr -- [options]"
  p.on("--port PORT", "Listen port (default 8765)") { |v| port = v.to_i }
  p.on("--size SIZE", "Asset body size, e.g. 4M (default 2M)") { |v| size_bytes = parse_size(v) }
  p.on("--throttle RATE", "Stream rate, e.g. 400k bytes/s (default 0 = unlimited)") { |v| throttle_bps = parse_size(v).to_i }
  p.on("--tag TAG", "Release tag (default v99.0.0)") { |v| tag = v }
  p.on("--body PATH", "Serve this file as the asset body") { |v| body_path = v }
  p.on("-h", "--help", "Show help") do
    puts p
    exit 0
  end
end

body = Bytes.empty
if bp = body_path
  raise "body file not found: #{bp}" unless File.file?(bp)
  body = File.read(bp).to_slice
else
  # Deterministic fill so size checks are stable; first line looks like a shell stub.
  io = IO::Memory.new
  io << "#!/bin/sh\necho mock-gori\n"
  pad = size_bytes - io.size
  pad = 0 if pad < 0
  io.write(Bytes.new(pad, 0x61_u8)) if pad > 0 # 'a'
  body = io.to_slice[0, Math.min(io.size, size_bytes)]
end

ver = tag.lchop('v').lchop('V')
asset_names = [
  "gori-v#{ver}-linux-x86_64",
  "gori-v#{ver}-linux-arm64",
  "gori-v#{ver}-osx-arm64.tar.gz",
  "gori-v#{ver}-osx-x86_64.tar.gz",
]

base = "http://127.0.0.1:#{port}"

def release_json(base : String, tag : String, names : Array(String), size : Int32) : String
  assets = names.map do |name|
    {
      "name"                 => name,
      "browser_download_url" => "#{base}/download/#{name}",
      "size"                 => size,
    }
  end
  {"tag_name" => tag, "assets" => assets}.to_json
end

server = HTTP::Server.new do |context|
  path = context.request.path
  case
  when path == "/repos/hahwul/gori/releases/latest"
    context.response.content_type = "application/json"
    context.response.print release_json(base, tag, asset_names, body.size)
  when path.starts_with?("/download/")
    name = path.lchop("/download/")
    unless asset_names.includes?(name)
      context.response.status = HTTP::Status::NOT_FOUND
      context.response.print "unknown asset"
      next
    end
    context.response.content_type = "application/octet-stream"
    context.response.content_length = body.size
    if throttle_bps > 0
      chunk = Math.max(1024, throttle_bps // 20)
      offset = 0
      while offset < body.size
        n = Math.min(chunk, body.size - offset)
        context.response.write(body[offset, n])
        context.response.flush
        offset += n
        sleep (n.to_f / throttle_bps).seconds if offset < body.size
      end
    else
      context.response.write(body)
    end
  else
    context.response.status = HTTP::Status::NOT_FOUND
    context.response.print "not found"
  end
end

server.bind_tcp("127.0.0.1", port)

puts "gori mock update server"
puts "  listen:    #{base}"
puts "  api:       #{base}/repos/hahwul/gori/releases/latest"
puts "  tag:       #{tag}"
puts "  assets:    #{asset_names.join(", ")}"
puts "  body:      #{body.size} bytes#{throttle_bps > 0 ? " @ #{throttle_bps} B/s" : ""}"
puts ""
puts "Try:"
puts "  GORI_UPDATE_API_URL=#{base}/repos/hahwul/gori/releases/latest ./bin/gori update"
puts ""
puts "Ctrl-C to stop."

server.listen
