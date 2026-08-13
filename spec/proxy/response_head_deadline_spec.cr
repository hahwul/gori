require "../spec_helper"
require "socket"

# The RESPONSE head is a slowloris surface too.
#
# `handle_request` has always bounded the CLIENT head with `deadline:`/`timeout_sock:` (the
# drip-feed a per-read timeout can't catch), and `Repeater::Engine#read_response_head` carries
# the same bound on the origin side citing this file. `ClientConn#safe_read_head` — the ONLY way
# a response head is read, on all three of its call sites — passed neither, so an origin emitting
# one header byte per <io_timeout never tripped a timer: the fiber, the client fd, the upstream fd
# and one of `Server`'s connection permits were pinned for as long as it cared to trickle (P6).
#
# The bound itself (raise after the deadline, restore the caller's baseline timeout) is proven in
# spec/proxy/socket_tuning_spec.cr against the same call shape; what these pin is that the proxy
# ASKS for it everywhere, and that asking for it does not cut a slow-but-progressing origin short.

private class HeadSink < Gori::Proxy::FlowSink
  def on_request(req : Gori::Store::CapturedRequest) : Int64
    1_i64
  end

  def on_response(resp : Gori::Store::CapturedResponse) : Nil
  end

  def on_ws_message(flow_id : Int64, direction : String, opcode : Int32, payload : Bytes,
                    shape : Gori::Proxy::WS::Shape = Gori::Proxy::WS::Shape::DEFAULT) : Nil
  end
end

describe "proxy head reads carry the slowloris deadline" do
  # Checked against the CODE rather than a list of call sites: a new head read inherits the rule
  # instead of a hand-maintained exemption list. `safe_read_head` was exactly the site that was
  # added later and never got the kwargs.
  it "passes deadline:/timeout_sock: at every Codec::Http1.read_head call under src/gori/proxy" do
    root = File.join(__DIR__, "..", "..", "src", "gori", "proxy")
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      src = File.read(path)
      # One level of nesting is enough for the `SocketTuning.underlying_socket(io)` argument.
      src.scan(/Codec::Http1\.read_head\((?:[^()]|\([^()]*\))*\)/m) do |m|
        call = m[0]
        next if call.includes?("deadline:") && call.includes?("timeout_sock:")
        offenders << "#{File.basename(path)}: #{call.gsub(/\s+/, " ")}"
      end
    end
    offenders.should be_empty
  end

  it "still proxies an origin that drips its response head slowly but finishes" do
    # The bound is on TOTAL head-assembly time, not on the gap between bytes, so a legitimately
    # slow origin (a CGI flushing headers as it computes them) must be unaffected.
    origin = TCPServer.new("127.0.0.1", 0)
    port = origin.local_address.port
    spawn do
      if conn = origin.accept?
        Gori::Proxy::Codec::Http1.read_head(conn)
        "HTTP/1.1 200 OK\r\nX-Slow: yes\r\nContent-Length: 2\r\n\r\n".each_byte do |b|
          conn.write_byte(b)
          conn.flush
          sleep 2.milliseconds
        end
        conn << "hi"
        conn.flush
        conn.close rescue nil
      end
    rescue
    end

    proxy = Gori::Proxy::Server.new("127.0.0.1", 0, HeadSink.new)
    proxy.start

    client = TCPSocket.new("127.0.0.1", proxy.port)
    client.read_timeout = 10.seconds
    client << "GET /slow HTTP/1.1\r\nHost: 127.0.0.1:#{port}\r\nConnection: close\r\n\r\n"
    client.flush

    head = Gori::Proxy::Codec::Http1.read_head(client).not_nil!
    String.new(head).should contain("X-Slow: yes")

    client.close
    proxy.stop
    origin.close rescue nil
  end
end
