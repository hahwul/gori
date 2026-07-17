# Umbrella for the OAST (out-of-band application security testing) engine. Store- and
# TUI-free (like src/gori/miner.cr / discover.cr), so the one engine drives the TUI OAST
# tab, `gori run oast`, and the MCP oast_* tools. See src/gori/oast/types.cr for the
# overview. RSA extends the in-process OpenSSL FFI (src/gori/proxy/tls/ffi.cr).
require "./oast/types"
require "./oast/http"
require "./oast/rsa"
require "./oast/crypto"
require "./oast/session"
require "./oast/provider"
require "./oast/presets"
require "./oast/present"
require "./oast/poller"
