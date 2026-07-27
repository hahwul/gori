require "./spec_helper"

private def with_listeners(primary_host : String, primary_port : Int32,
                           entries : Array(Gori::Settings::Listener), &)
  prev_host = Gori::Settings.bind_host
  prev_port = Gori::Settings.bind_port
  prev = Gori::Settings.listeners
  begin
    Gori::Settings.project_bind_host = nil
    Gori::Settings.project_bind_port = nil
    Gori::Settings.bind_host = primary_host
    Gori::Settings.bind_port = primary_port
    Gori::Settings.listeners = entries
    yield
  ensure
    Gori::Settings.bind_host = prev_host
    Gori::Settings.bind_port = prev_port
    Gori::Settings.listeners = prev
  end
end

private def listener(host : String, port : Int32, mode : String = "proxy",
                     target_port : Int32 = 0) : Gori::Settings::Listener
  Gori::Settings::Listener.new(host, port, mode, target_port)
end

describe Gori::Settings do
  describe ".valid_listeners" do
    it "drops an entry that fails validation" do
      with_listeners("127.0.0.1", 8070, [
        listener("127.0.0.1", 9090),
        listener("not a host", 9091),              # invalid bind address
        listener("127.0.0.1", 9092, "bogus"),      # unknown mode
        listener("127.0.0.1", 9093, "proxy", 443), # target_port on a proxy listener
      ]) do
        Gori::Settings.valid_listeners.map(&.port).should eq([9090])
      end
    end

    # The de-duplication that matters: a duplicate of the primary bind cannot bind, and
    # before this compared raw strings — so every alternate spelling of the same socket
    # survived here and then failed at bind time, reported as a listener error about an
    # address the operator can see configured exactly once.
    it "drops a duplicate of the primary bind however it is spelled" do
      with_listeners("127.0.0.1", 8070, [
        listener("127.0.0.1", 8070),
        listener("localhost", 8070),
        listener("LocalHost", 8070),
        listener("  127.0.0.1  ", 8070),
      ]) do
        Gori::Settings.valid_listeners.should be_empty
      end
    end

    it "folds the IPv6 loopback's bracketed and named spellings" do
      with_listeners("::1", 8070, [
        listener("[::1]", 8070),
        listener("ip6-localhost", 8070),
      ]) do
        Gori::Settings.valid_listeners.should be_empty
      end
    end

    # A wildcard primary already owns every address of its family on that port.
    it "drops a concrete listener that sits under a wildcard primary of the same family" do
      with_listeners("0.0.0.0", 8070, [listener("127.0.0.1", 8070)]) do
        Gori::Settings.valid_listeners.should be_empty
      end
      with_listeners("127.0.0.1", 8070, [listener("0.0.0.0", 8070)]) do
        Gori::Settings.valid_listeners.should be_empty
      end
      # Different family: not folded — a v4 wildcard does not cover ::1, and the kernel has
      # the last word anyway (Session reports a failed bind per listener).
      with_listeners("0.0.0.0", 8070, [listener("::1", 8070)]) do
        Gori::Settings.valid_listeners.size.should eq(1)
      end
    end

    it "keeps a listener that only shares the host, or only the port" do
      with_listeners("127.0.0.1", 8070, [
        listener("127.0.0.1", 8071),
        listener("192.168.1.10", 8070),
      ]) do
        Gori::Settings.valid_listeners.map(&.port).should eq([8071, 8070])
      end
    end
  end

  describe "Listener#effective_target_port" do
    it "uses the configured port, else the conventional one for the protocol" do
      listener("127.0.0.1", 8443, "transparent", 8443).effective_target_port(true).should eq(8443)
      listener("127.0.0.1", 8443, "transparent").effective_target_port(true).should eq(443)
      listener("127.0.0.1", 8080, "transparent").effective_target_port(false).should eq(80)
    end
  end
end
