require "../spec_helper"
require "socket"

# NOTE ON WHAT THIS FILE CAN AND CANNOT PROVE. The two lookups are platform FFI, and no spec
# that runs on a developer's machine exercises them: reaching the Linux branch needs an iptables
# REDIRECT in front of the listener, and the macOS branch needs a pf rule AND root (`/dev/pf` is
# 0600 root:wheel). Those were verified by running a real redirect — see the PR for #503, which
# records the transcript. What IS deterministic everywhere, and what this file covers, is the
# NO-ANSWER path: that an ordinary un-redirected connection produces nil rather than a wrong
# destination, which is the property the fallback rests on.
describe Gori::Proxy::OrigDst do
  describe ".lookup" do
    # The important negative. On Linux `SO_ORIGINAL_DST` is answered out of conntrack, and for a
    # tracked-but-not-NATted connection it hands back the socket's OWN local address — which,
    # taken at face value, would make gori dial itself once per connection until the listener
    # wedges. Verified live: on a direct connection the raw getsockopt returned 127.0.0.1:<the
    # listener's own port> and the guard turned it into the nil asserted here.
    it "has no answer for a connection nothing redirected" do
      server = TCPServer.new("127.0.0.1", 0)
      begin
        client = TCPSocket.new("127.0.0.1", server.local_address.port)
        accepted = server.accept
        begin
          Gori::Proxy::OrigDst.lookup(accepted).should be_nil
        ensure
          accepted.close
          client.close
        end
      ensure
        server.close
      end
    end
  end

  describe ".dial_host" do
    # A dual-stack listener reports a redirected v4 peer in the v4-mapped form. That string is
    # what would otherwise reach the resolver, the upstream-reuse pool key and History, so it is
    # unwrapped once here rather than at each of them.
    it "unwraps a v4-mapped address to its dotted form" do
      addr = Socket::IPAddress.new("::ffff:10.0.0.5", 8443)
      Gori::Proxy::OrigDst.dial_host(addr).should eq("10.0.0.5")
    end

    it "leaves a plain v4 or v6 address alone" do
      Gori::Proxy::OrigDst.dial_host(Socket::IPAddress.new("10.0.0.5", 80)).should eq("10.0.0.5")
      Gori::Proxy::OrigDst.dial_host(Socket::IPAddress.new("::1", 80)).should eq("::1")
    end
  end

  describe ".v4ish?" do
    it "counts the v4-mapped form as v4, because the redirect that made it was v4" do
      Gori::Proxy::OrigDst.v4ish?(Socket::IPAddress.new("::ffff:10.0.0.5", 1)).should be_true
      Gori::Proxy::OrigDst.v4ish?(Socket::IPAddress.new("10.0.0.5", 1)).should be_true
      Gori::Proxy::OrigDst.v4ish?(Socket::IPAddress.new("::1", 1)).should be_false
    end
  end

  # #493's discipline needs both halves of the sentence to exist: which mechanism, and — when
  # there is none — why not. A blank either way leaves the operator guessing, which is the whole
  # failure mode being fixed.
  describe "the operator-facing readout" do
    it "names a mechanism" do
      Gori::Proxy::OrigDst.mechanism.should_not be_empty
    end

    it "explains an unavailable lookup, or says nothing when it is available" do
      if reason = Gori::Proxy::OrigDst.unavailable_reason
        reason.should_not be_empty
      end
      {% if flag?(:linux) %}
        # Linux needs no privilege and no device: the option is always askable, and a per
        # connection "no NAT entry" is a different answer from "cannot look up at all".
        Gori::Proxy::OrigDst.unavailable_reason.should be_nil
      {% end %}
    end
  end
end
