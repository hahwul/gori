# What one MITM leaf context costs to build and to keep cached: the stdlib's
# `Context::Server.new` (which loads the system CA bundle into every context) against
# `ContextFactory.lean_server` (the same defaults without it).
#
# `authority` is the whole cached leaf as CertAuthority keeps it (keygen, cert, context),
# which is what sizes MAX_LEAVES.
#
# One mode per process, so the RSS column is not polluted by the other variant's heap:
#
#   crystal build --release --no-debug bench/tls_context_bench.cr -o bin/tls_context_bench
#   bin/tls_context_bench stdlib 256
#   bin/tls_context_bench lean 256
#   bin/tls_context_bench authority 1024
require "file_utils"
require "../src/gori"

mode = ARGV[0]? || "lean"
n = (ARGV[1]? || "256").to_i
abort "mode must be lean, stdlib or authority" unless mode.in?("lean", "stdlib", "authority")

def rss_kb : Int64
  `ps -o rss= -p #{Process.pid}`.strip.to_i64
end

if mode == "authority"
  dir = File.tempname("gori-ctx-bench")
  begin
    ca = Gori::Proxy::Tls::CertAuthority.load_or_create(dir)
    before = rss_kb
    elapsed = Time.measure { n.times { |i| ca.context_for("h#{i}.bench.test") } }
    GC.collect
    grown = rss_kb - before
    printf("authority n=%d  %.3f ms/leaf  rss +%.1f MB (%.3f MB/leaf)\n", n,
      elapsed.total_milliseconds / n, grown / 1024.0, grown / 1024.0 / n)
  ensure
    FileUtils.rm_rf(dir)
  end
  exit
end

root, root_key = Gori::Proxy::Tls::CertBuilder.build_root("gori bench")
# Mint the certs first: the question is the context, not the ECDSA keygen.
leaves = Array.new(n) { |i| Gori::Proxy::Tls::CertBuilder.build_leaf("h#{i}.bench.test", root, root_key) }

base_rss = rss_kb
cached = [] of OpenSSL::SSL::Context::Server
elapsed = Time.measure do
  leaves.each do |(cert, key)|
    ctx = mode == "lean" ? Gori::Proxy::Tls::ContextFactory.lean_server : OpenSSL::SSL::Context::Server.new
    LibSSL.ssl_ctx_use_certificate(ctx.to_unsafe, cert.handle)
    LibSSL.ssl_ctx_use_privatekey(ctx.to_unsafe, key.handle)
    ctx.alpn_protocol = "h2"
    cached << ctx
  end
end
GC.collect
grown = rss_kb - base_rss

printf("%-6s n=%d  build %.3f ms/ctx  rss +%.1f MB (%.2f MB/ctx)\n", mode, n,
  elapsed.total_milliseconds / n, grown / 1024.0, grown / 1024.0 / n)
cached.size # keep every context alive until after the RSS read
