require "../spec_helper"
require "socket"

private def tcp_pair(&)
  srv = TCPServer.new("127.0.0.1", 0)
  client = TCPSocket.new("127.0.0.1", srv.local_address.port)
  server = srv.accept
  begin
    yield client, server
  ensure
    client.close rescue nil
    server.close rescue nil
    srv.close
  end
end

describe Gori::Proxy::SocketResidue do
  describe ".pending?" do
    it "is false on an idle socket and true, without consuming, once the peer has sent" do
      tcp_pair do |client, server|
        Gori::Proxy::SocketResidue.pending?(server).should be_false
        client << "GET /b HTTP/1.1\r\n\r\n"
        client.flush
        sleep 50.milliseconds
        Gori::Proxy::SocketResidue.pending?(server).should be_true
        Gori::Proxy::SocketResidue.pending?(server).should be_true
        server.read_byte.should eq('G'.ord) # nothing was consumed
      end
    end

    it "sees bytes already pulled into the buffered layer" do
      tcp_pair do |client, server|
        client << "AB"
        client.flush
        server.read_byte.should eq('A'.ord) # the buffered read pulls "B" off the socket too
        Gori::Proxy::SocketResidue.pending?(server).should be_true
      end
    end

    it "sees an unread PrefixIO prefix and looks through it once the prefix is read" do
      tcp_pair do |_client, server|
        prefixed = Gori::Proxy::PrefixIO.new(Bytes[0x16_u8], server)
        Gori::Proxy::SocketResidue.pending?(prefixed).should be_true
        prefixed.read(Bytes.new(1))
        Gori::Proxy::SocketResidue.pending?(prefixed).should be_false
      end
    end

    it "reports a transport it cannot look inside as pending" do
      Gori::Proxy::SocketResidue.pending?(IO::Memory.new).should be_true
    end
  end
end
