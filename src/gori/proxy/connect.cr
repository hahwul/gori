require "./sink"
require "./conn/self_page"
require "./codec/http1"
require "./socket_tuning"

module Gori::Proxy
  # The CONNECT -> TLS-MITM handoff seam. A ClientConn that receives `CONNECT
  # host:port` replies 200 and then either hands the raw client socket to a
  # TlsMitm (intercept + capture, Step 6) or blind-tunnels it (when MITM is off).
  #
  # Defining the interface here keeps the TLS subsystem (which depends on the
  # FFI cert authority) decoupled from the connection loop.
  abstract class TlsMitm
    # Wrap `client` (already past the 200 reply) as a TLS server using a
    # per-host leaf, dial host:port as a TLS client, and run the decrypted
    # HTTP/1.1 request loop, capturing flows to `sink`.
    abstract def intercept(host : String, port : Int32, client : IO, sink : FlowSink) : Nil

    # Serve the self-page over TLS after a CONNECT to a RESERVED host (SelfPage.magic_host?)
    # — a proxy-configured client that browsed to `https://gori.proxy/`. No origin is dialed
    # and nothing is captured. The client sees gori's own leaf, which it does NOT trust yet
    # (that is the very thing it came here to fix), so a certificate warning is expected;
    # clicking through is what reaches the download. Default no-op: a bare TlsMitm has no CA
    # to mint a leaf with, and its serve_landing? below is already false, so ClientConn
    # never routes here.
    def intercept_self_page(host : String, client : IO, listen : {String, Int32}) : Nil
    end

    # The self-page response bytes for one request, assembled from this seam's own CA
    # accessors. GET/HEAD serve the page; anything else gets an explicit 405, because the
    # CONNECT-tunnelled callers have no origin to fall through to and silence there would
    # just hang the client. One place for every caller — ClientConn's direct-hit path, its
    # plaintext CONNECT path, and the TLS tunnel — so they can't drift.
    def self_page_reply(method : String, target : String, listen : {String, Int32}) : Bytes
      head_only = method.compare("HEAD", case_insensitive: true) == 0
      unless head_only || method.compare("GET", case_insensitive: true) == 0
        return SelfPage.method_not_allowed(head_only)
      end
      SelfPage.respond(target,
        pem: ca_cert_pem, der: ca_cert_der, spki: ca_spki_sha256,
        ca_path: ca_cert_path, listen: listen, version: Gori::VERSION, head_only: head_only)
    end

    # Read ONE request off an already-established stream and answer it with the self page,
    # then return so the caller can close. One request is the whole protocol here: every
    # SelfPage response is `Connection: close`, and the page has no subresources (its CSS is
    # inlined, the favicon 204s), so a browser following the `/ca.der` link simply opens a
    # fresh connection. The head read carries the same slowloris bound as the main request
    # loop. Best-effort: a dead peer, a torn-down stream, or a CA file deleted underneath us
    # (ca_cert_pem reads from disk and raises) just ends the connection.
    def serve_self_page_once(stream : IO, listen : {String, Int32}) : Nil
      head = Codec::Http1.read_head(stream,
        deadline: SocketTuning::HEAD_DEADLINE, timeout_sock: SocketTuning.underlying_socket(stream))
      return unless head
      req = Codec::Http1.parse_request_head(head)
      stream.write(self_page_reply(req.method, req.target, listen))
      stream.flush
    rescue
    end

    # Root-CA accessors for the self-serve landing page ClientConn serves when a
    # browser hits the listener directly. Defined here (returning plain types, not
    # the FFI CertAuthority) so the connection loop stays decoupled from the TLS
    # subsystem; Tunnel overrides them from its @ca. Defaults mean "no MITM CA to
    # hand out" — a nil @tls or a bare TlsMitm just omits the certificate download.
    def serve_landing? : Bool
      false
    end

    def ca_cert_pem : String?
      nil
    end

    def ca_cert_der : Bytes?
      nil
    end

    def ca_cert_path : String?
      nil
    end

    def ca_spki_sha256 : String?
      nil
    end
  end
end
