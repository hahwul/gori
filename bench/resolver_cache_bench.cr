# What an upstream dial spends resolving its host: a direct `getaddrinfo` (what every dial
# did before ResolverCache) against a cache hit. getaddrinfo is a blocking libc call, so its
# whole latency is time the one scheduler thread spends not running any proxy fiber.
#
#   crystal build --release --no-debug bench/resolver_cache_bench.cr -o bin/resolver_cache_bench
#   bin/resolver_cache_bench                 # localhost
#   bin/resolver_cache_bench example.com 200 # a real name (needs a resolver)
require "../src/gori/proxy/resolver_cache"

host = ARGV[0]? || "localhost"
n = (ARGV[1]? || "2000").to_i

direct = Time.measure { n.times { Socket::Addrinfo.tcp(host, 443) } }

cache = Gori::Proxy::ResolverCache.new
cache.resolve(host, 443) # warm
hit = Time.measure { n.times { cache.resolve(host, 443) } }

printf("%s x%d  getaddrinfo %.1f us/lookup  cache hit %.3f us/lookup\n", host, n,
  direct.total_microseconds / n, hit.total_microseconds / n)
