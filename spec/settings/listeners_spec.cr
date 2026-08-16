require "../spec_helper"

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
                     target_port : Int32 = 0, origin : String = "",
                     rewrite_host : Bool = false) : Gori::Settings::Listener
  Gori::Settings::Listener.new(host, port, mode, target_port, origin, rewrite_host)
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

    # `bind_host_error` accepts every all-zero spelling and they all bind as a full wildcard,
    # but `wildcard_bind?` was a two-string literal test — so the fold above happened under
    # `::` and not under `::0`, and the entry it should have dropped bound beside the wildcard,
    # failed EADDRINUSE, and was reported as a listener error for an address configured once.
    # `Upstream.unspecified?` already carries this same fix, for the same reason.
    it "folds every spelling of the wildcard, not just 0.0.0.0 and ::" do
      ["::0", "0:0:0:0:0:0:0:0", "0000:0000:0000:0000:0000:0000:0000:0000"].each do |spelling|
        with_listeners(spelling, 8070, [listener("::1", 8070)]) do
          Gori::Settings.valid_listeners.should be_empty
        end
        with_listeners("::1", 8070, [listener(spelling, 8070)]) do
          Gori::Settings.valid_listeners.should be_empty
        end
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

  describe "reverse listeners (#499)" do
    it "parses an origin into scheme/host/port, defaulting the port from the scheme" do
      Gori::Settings.parse_origin("https://api.acme.test").should eq({"https", "api.acme.test", 443})
      Gori::Settings.parse_origin("http://api.acme.test").should eq({"http", "api.acme.test", 80})
      Gori::Settings.parse_origin("http://127.0.0.1:3000").should eq({"http", "127.0.0.1", 3000})
      # The SCHEME is folded (it selects gori's behaviour) but the HOST is not: those bytes
      # become the SNI and the minted leaf's name, and rewriting an operator-supplied host is
      # the provenance rule's business. DNS and certificate matching are case-insensitive
      # anyway, and `same_bind_host?` folds case on its own for the self-target test below.
      Gori::Settings.parse_origin("HTTPS://API.acme.test:8443").should eq({"https", "API.acme.test", 8443})
      # Crystal keeps the brackets on a v6 literal; parse_origin strips them, because what
      # comes out of it is dialled and used as the SNI.
      Gori::Settings.parse_origin("http://[::1]:3000").should eq({"http", "::1", 3000})
    end

    # A bare authority is REFUSED rather than assumed http: the assumption would silently
    # decide whether gori speaks TLS to the operator's origin.
    it "refuses an origin that is not an absolute http(s) URL" do
      Gori::Settings.parse_origin("api.acme.test:8443").should be_nil
      Gori::Settings.parse_origin("ftp://api.acme.test").should be_nil
      Gori::Settings.parse_origin("https://").should be_nil
      Gori::Settings.parse_origin("").should be_nil
    end

    it "requires an origin in reverse mode and refuses one outside it" do
      with_listeners("127.0.0.1", 8070, [] of Gori::Settings::Listener) do
        Gori::Settings.listener_error(listener("127.0.0.1", 9000, "reverse")).to_s
          .should contain("needs an origin")
        Gori::Settings.listener_error(listener("127.0.0.1", 9000, "reverse", origin: "api.acme.test")).to_s
          .should contain("absolute http(s) URL")
        # The target_port precedent, applied in the other direction: a field in the wrong
        # mode is refused, never ignored.
        Gori::Settings.listener_error(listener("127.0.0.1", 9000, "proxy", origin: "https://api.acme.test")).to_s
          .should contain("origin only applies to a reverse listener")
        Gori::Settings.listener_error(listener("127.0.0.1", 9000, "transparent", rewrite_host: true)).to_s
          .should contain("rewrite_host only applies to a reverse listener")
        Gori::Settings.listener_error(listener("127.0.0.1", 9000, "reverse", origin: "https://api.acme.test"))
          .should be_nil
      end
    end

    # The config-time half of the self-loop guard. A reverse origin is CONFIGURATION, so
    # unlike the forward/transparent cases this loop is one an operator creates by typing.
    it "refuses an origin that points back at gori itself" do
      with_listeners("127.0.0.1", 8070, [listener("127.0.0.1", 9001, "transparent")]) do
        # the primary bind, in each spelling same_bind_host? folds
        Gori::Settings.listener_error(listener("127.0.0.1", 9000, "reverse", origin: "http://127.0.0.1:8070")).to_s
          .should contain("points back at gori itself")
        Gori::Settings.listener_error(listener("127.0.0.1", 9000, "reverse", origin: "http://localhost:8070")).to_s
          .should contain("points back at gori itself")
        # another configured listener
        Gori::Settings.listener_error(listener("127.0.0.1", 9000, "reverse", origin: "http://127.0.0.1:9001")).to_s
          .should contain("points back at gori itself")
        # its own socket
        Gori::Settings.listener_error(listener("127.0.0.1", 9000, "reverse", origin: "http://127.0.0.1:9000")).to_s
          .should contain("points back at gori itself")
        # a real origin that merely shares the port is untouched
        Gori::Settings.listener_error(listener("127.0.0.1", 9000, "reverse", origin: "http://api.acme.test:8070"))
          .should be_nil
      end
    end

    it "covers a wildcard primary, which owns every address of its family on that port" do
      with_listeners("0.0.0.0", 8070, [] of Gori::Settings::Listener) do
        Gori::Settings.listener_error(listener("127.0.0.1", 9000, "reverse", origin: "http://127.0.0.1:8070")).to_s
          .should contain("points back at gori itself")
      end
    end

    # Dropping an unusable entry is right; dropping it SILENTLY is what left the operator with
    # no signal but traffic that never arrived. Session seeds listener_errors from this.
    it "reports why each dropped entry was dropped" do
      with_listeners("127.0.0.1", 8070, [
        listener("127.0.0.1", 9000, "reverse"),
        listener("127.0.0.1", 9001, "reverse", origin: "https://api.acme.test"),
      ]) do
        Gori::Settings.valid_listeners.map(&.port).should eq([9001])
        errs = Gori::Settings.listener_config_errors
        errs.size.should eq(1)
        errs[0].should start_with("127.0.0.1:9000 —")
        errs[0].should contain("needs an origin")
      end
    end

    it "round-trips the new fields through serialization" do
      with_listeners("127.0.0.1", 8070, [
        listener("0.0.0.0", 9000, "reverse", origin: "https://api.acme.test:8443", rewrite_host: true),
      ]) do
        json = JSON.parse(Gori::Settings.export_document(["listeners"]))["listeners"][0]
        json["origin"].as_s.should eq("https://api.acme.test:8443")
        json["rewrite_host"].as_bool.should be_true
        json["target_port"]?.should be_nil # omitted when unset, as before
      end
    end

    it "omits the reverse fields for a listener that has none" do
      with_listeners("127.0.0.1", 8070, [listener("127.0.0.1", 9000, "transparent", 443)]) do
        json = JSON.parse(Gori::Settings.export_document(["listeners"]))["listeners"][0]
        json["origin"]?.should be_nil
        json["rewrite_host"]?.should be_nil
        json["target_port"].as_i.should eq(443)
      end
    end

    it "exposes the parsed origin off the record" do
      listener("127.0.0.1", 9000, "reverse", origin: "https://api.acme.test")
        .origin_target.should eq({"https", "api.acme.test", 443})
      listener("127.0.0.1", 9000, "transparent").origin_target.should be_nil
    end
  end

  describe "Listener#effective_target_port" do
    it "uses the configured port, else the conventional one for the protocol" do
      listener("127.0.0.1", 8443, "transparent", 8443).effective_target_port(true).should eq(8443)
      listener("127.0.0.1", 8443, "transparent").effective_target_port(true).should eq(443)
      listener("127.0.0.1", 8080, "transparent").effective_target_port(false).should eq(80)
    end
  end

  # #508: the live reconcile validates a set it read from DISK and deliberately does not write
  # back over `Settings.listeners` (that would let the next save clobber a hand edit), so every
  # validator has to be able to say which set it means.
  describe "validating a candidate set (#508)" do
    it "checks the loop rule against `among`, not the class property" do
      other = listener("127.0.0.1", 9100)
      rev = listener("127.0.0.1", 9000, "reverse", origin: "http://127.0.0.1:9100")
      with_listeners("127.0.0.1", 8070, [] of Gori::Settings::Listener) do
        # Not in Settings.listeners: nothing to loop against, so it validates.
        Gori::Settings.listener_error(rev).should be_nil
        # Named in the candidate set: the origin points at another socket in the same edit.
        Gori::Settings.listener_error(rev, [rev, other]).should_not be_nil
      end
    end

    it "filters and reports errors over the given set" do
      set = [listener("127.0.0.1", 9000), listener("127.0.0.1", 9001, "reverse")]
      with_listeners("127.0.0.1", 8070, [] of Gori::Settings::Listener) do
        Gori::Settings.valid_listeners(set).map(&.port).should eq([9000])
        Gori::Settings.listener_config_errors(set).size.should eq(1)
        # The class property is untouched by validating somebody else's array.
        Gori::Settings.valid_listeners.should be_empty
        Gori::Settings.listeners.should be_empty
      end
    end
  end

  describe ".disk_listeners?" do
    it "separates an unreadable file from an absent section" do
      dir = File.tempname("gori-disk-listeners")
      Dir.mkdir_p(dir)
      path = File.join(dir, "settings.json")
      begin
        Gori::Settings.path_override = path
        # No file at all, and a file with no `listeners` key, both mean "the section is empty".
        Gori::Settings.disk_listeners?.should eq([] of Gori::Settings::Listener)
        File.write(path, %({"theme": "dark"}))
        Gori::Settings.disk_listeners?.should eq([] of Gori::Settings::Listener)

        File.write(path, %({"listeners": [{"host": "127.0.0.1", "port": 9000}]}))
        Gori::Settings.disk_listeners?.try(&.map(&.port)).should eq([9000])

        # Unparseable is NOT "empty": a reconcile acting on that would tear sockets down over a
        # typo in an unrelated section, so it gets nil and refuses.
        File.write(path, "{not json")
        Gori::Settings.disk_listeners?.should be_nil
        # The drift CHECK keeps its old fallback — it only decides whether to say something.
        with_listeners("127.0.0.1", 8070, [listener("127.0.0.1", 9000)]) do
          Gori::Settings.disk_listeners.map(&.port).should eq([9000])
        end
      ensure
        Gori::Settings.path_override = nil
        FileUtils.rm_rf(dir)
      end
    end
  end
end
