require "openssl"

# Every TLS context gori makes keeps the record layer in userspace: kernel TLS stays off.
#
# OpenSSL 3 hands a connection's record layer to the kernel when its context carries
# `SSL_OP_ENABLE_KTLS`, and the system openssl.cnf can turn that on for every context. Crystal
# 1.22's BIO honours it, and its kTLS read path reports a socket error (ECONNRESET, a read
# timeout) as a successful zero-byte read, which OpenSSL then calls EOF. gori is built on the
# userspace path: `SocketResidue` inspects the ciphertext Crystal's own `IO::Buffered` holds
# under the SSL socket, which kTLS bypasses, and it tells an idle socket from a closed one, and
# a reset from a FIN, by whether the read raises. On the ubuntu-26.04 CI runner an idle pooled
# socket read as Closed and an injected reset as EOF until this was cleared.
#
# Both constructors, so `Context::Client.insecure` is covered too. `ENABLE_KTLS` is 0 below
# OpenSSL 3, where removing it is a no-op.
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
