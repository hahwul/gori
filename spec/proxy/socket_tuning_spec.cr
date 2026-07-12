require "../spec_helper"
require "socket"

alias ST = Gori::Proxy::SocketTuning

describe Gori::Proxy::SocketTuning do
  describe ".underlying_socket" do
    it "returns a raw Socket unchanged" do
      a, b = UNIXSocket.pair
      begin
        ST.underlying_socket(a).should be(a)
      ensure
        a.close; b.close
      end
    end

    it "unwraps a PrefixIO to its inner socket" do
      a, b = UNIXSocket.pair
      begin
        pio = Gori::Proxy::PrefixIO.new("PRI".to_slice, a)
        ST.underlying_socket(pio).should be(a)
      ensure
        a.close; b.close
      end
    end

    it "returns nil for a non-socket IO and for nil" do
      ST.underlying_socket(IO::Memory.new).should be_nil
      ST.underlying_socket(nil).should be_nil
    end
  end

  describe ".arm / .relax" do
    it "sets then clears the read+write timeout on the socket" do
      a, b = UNIXSocket.pair
      begin
        ST.arm(a, 7.seconds)
        a.read_timeout.should eq(7.seconds)
        a.write_timeout.should eq(7.seconds)
        ST.relax(a)
        a.read_timeout.should be_nil
        a.write_timeout.should be_nil
      ensure
        a.close; b.close
      end
    end

    it "arms through a PrefixIO wrapper (reaches the underlying socket)" do
      a, b = UNIXSocket.pair
      begin
        ST.arm(Gori::Proxy::PrefixIO.new(Bytes.empty, a), 3.seconds)
        a.read_timeout.should eq(3.seconds)
      ensure
        a.close; b.close
      end
    end

    it "no-ops (never raises) on a non-socket IO" do
      ST.arm(IO::Memory.new, 5.seconds) # nothing to set — must not raise
      ST.relax(IO::Memory.new)
    end
  end

  describe ".enable_keepalive" do
    it "never raises, even where the tunables are unsupported" do
      a, b = UNIXSocket.pair
      begin
        ST.enable_keepalive(a) # a UNIX socket may reject SO_KEEPALIVE tunables — must be swallowed
      ensure
        a.close; b.close
      end
    end
  end
end

describe "Http1.read_head with a head-completion deadline (drip-feed slowloris bound)" do
  it "raises after the deadline when the head never completes" do
    a, b = UNIXSocket.pair
    begin
      # A partial head (no terminating CRLFCRLF): the first bytes arrive, then the reader blocks.
      a.write("GET / HTTP/1.1\r\nHost: x\r\n".to_slice)
      a.flush
      expect_raises(IO::TimeoutError) do
        Gori::Proxy::Codec::Http1.read_head(b, deadline: 100.milliseconds, timeout_sock: b)
      end
    ensure
      a.close; b.close
    end
  end

  it "returns a complete head and RESTORES the baseline timeout for the body read" do
    a, b = UNIXSocket.pair
    begin
      b.read_timeout = 5.seconds # caller's baseline (armed by `run`)
      a.write("GET / HTTP/1.1\r\n\r\n".to_slice)
      a.flush
      head = Gori::Proxy::Codec::Http1.read_head(b, deadline: 2.seconds, timeout_sock: b)
      String.new(head.not_nil!).should eq("GET / HTTP/1.1\r\n\r\n")
      b.read_timeout.should eq(5.seconds) # restored, so the following body read isn't left on a shrunk budget
    ensure
      a.close; b.close
    end
  end

  it "is byte-for-byte the original read_head when no deadline is armed" do
    io = IO::Memory.new("GET /x HTTP/1.1\r\nA: b\r\n\r\nBODY")
    head = Gori::Proxy::Codec::Http1.read_head(io)
    String.new(head.not_nil!).should eq("GET /x HTTP/1.1\r\nA: b\r\n\r\n")
    io.gets_to_end.should eq("BODY") # body boundary intact
  end
end
