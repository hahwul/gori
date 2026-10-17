require "socket"

# An h1 origin answering every connection's request with an event stream (#1631): one event
# every `every`, `events` of them and then the end, or forever when nil. A chunked event is
# TWO chunks, so its blank line and a chunk's CRLF meet the way they do on the wire, and it
# carries two `data` lines, so a count over the raw chunked bytes would come out double.
def start_sse_origin(chunked : Bool = true, content_type : String = "text/event-stream",
                     every : Time::Span = 10.milliseconds, events : Int32? = nil) : Int32
  origin = TCPServer.new("127.0.0.1", 0)
  port = origin.local_address.port
  spawn do
    while accepted = origin.accept?
      spawn_with(accepted) do |conn|
        conn.read_timeout = 30.seconds
        loop do
          Gori::Proxy::Codec::Http1.read_head(conn)
          conn << "HTTP/1.1 200 OK\r\nContent-Type: " << content_type << "\r\n"
          conn << (chunked ? "Transfer-Encoding: chunked\r\n\r\n" : "Connection: close\r\n\r\n")
          n = 0
          until events && n >= events
            parts = {"data: #{n}\n", "data: x\n\n"}
            if chunked
              parts.each { |part| conn << part.bytesize.to_s(16) << "\r\n" << part << "\r\n" }
            else
              parts.each { |part| conn << part }
            end
            conn.flush
            n += 1
            sleep every
          end
          conn << "0\r\n\r\n" if chunked
          conn.flush
          break unless chunked # close-delimited: the close IS the end
        end
      rescue
      ensure
        conn.close rescue nil
      end
    end
  rescue
  end
  port
end
