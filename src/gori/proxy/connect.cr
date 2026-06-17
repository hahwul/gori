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
  end
end
