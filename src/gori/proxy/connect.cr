require "./sink"

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
