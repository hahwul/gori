require "openssl"

# Every TLS context gori makes keeps the record layer in userspace: kernel TLS stays off.
#
# A fresh SSL_CTX can come with `SSL_OP_ENABLE_KTLS` already set (the ubuntu-26.04 CI runner's
# OpenSSL and the Windows build's both do), and Crystal 1.22's BIO then hands the record layer
# to the kernel after the handshake. gori is built on the userspace path, for two reasons:
#
# - It layers TLS over IOs that are not a `Socket` (a peeked client stream, an upstream
#   proxy's TLS socket), and 1.22's BIO casts its IO to `Socket` when KTLS starts, raising a
#   TypeCastError.
# - `SocketResidue` inspects the ciphertext Crystal's own `IO::Buffered` holds under the SSL
#   socket, which kTLS bypasses, and tells an idle socket from a closed one, and a reset from
#   a FIN, by whether the read raises. 1.22's kTLS read path returns a socket error
#   (ECONNRESET, a read timeout) as a zero-byte read, which OpenSSL calls EOF: on
#   ubuntu-26.04 an idle pooled socket read as Closed and an injected reset as EOF.
#
# Both stdlib constructors, so `Context::Client.insecure` is covered too; gori's own
# `Context::Server.gori_bare` (context_factory.cr) clears it beside its other options.
# `ENABLE_KTLS` is 0 below OpenSSL 3, where removing it is a no-op.
abstract class OpenSSL::SSL::Context
  protected def initialize(method : LibSSL::SSLMethod)
    previous_def
    remove_options(OpenSSL::SSL::Options::ENABLE_KTLS)
  end

  protected def _initialize_insecure(method : LibSSL::SSLMethod)
    previous_def
    remove_options(OpenSSL::SSL::Options::ENABLE_KTLS)
  end
end
