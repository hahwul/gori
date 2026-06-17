# Binary entrypoint. The library (src/gori.cr) has no top-level execution so it
# can be required by specs; this thin file is the shard build target.
require "./gori"

Gori::CLI.run
