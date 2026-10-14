require "../../spec_helper"

private alias KeyLog = Gori::Proxy::Tls::KeyLog

private class BrokenIO < IO
  def read(slice : Bytes) : Int32
    0
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("No space left on device")
  end
end

private def with_tempdir(&)
  dir = File.tempname("gori-keylog")
  Dir.mkdir_p(dir)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

private def keylog_callback?(ctx : OpenSSL::SSL::Context) : Bool
  !LibSSL.ssl_ctx_get_keylog_callback(ctx.to_unsafe).pointer.null?
end

# One handshake between a gori leaf context and a stdlib client on 127.0.0.1 (not ::1, which
# fails locally on macOS and hides regressions). Returns once both ends are done.
private def keylog_handshake(tls12 : Bool = false) : Nil
  root, root_key = Gori::Proxy::Tls::CertBuilder.build_root("gori keylog spec")
  leaf, leaf_key = Gori::Proxy::Tls::CertBuilder.build_leaf("keylog.test", root, root_key)
  ctx = Gori::Proxy::Tls::ContextFactory.server_context(leaf, leaf_key, ca_cert: root, advertise_h2: false)
  server = TCPServer.new("127.0.0.1", 0)
  done = Channel(Nil).new
  spawn do
    ssl = OpenSSL::SSL::Socket::Server.new(server.accept, ctx, sync_close: true)
    ssl.puts "hi"
    ssl.flush
    ssl.close rescue nil
  ensure
    done.send(nil)
  end
  client_ctx = OpenSSL::SSL::Context::Client.insecure
  client_ctx.add_options(OpenSSL::SSL::Options::NO_TLS_V1_3) if tls12
  client = OpenSSL::SSL::Socket::Client.new(TCPSocket.new("127.0.0.1", server.local_address.port),
    context: client_ctx, sync_close: true, hostname: "keylog.test")
  client.gets.should eq("hi")
  done.receive
  client.close rescue nil
  server.close
end

{% if LibSSL.has_method?(:ssl_ctx_get_keylog_callback) %}
describe KeyLog do
  after_each { KeyLog.reset }

  it "stays off, installs nothing and creates no file when neither variable is set" do
    KeyLog.configure({} of String => String).should be_nil
    KeyLog.active?.should be_false
    leaf, key = Gori::Proxy::Tls::CertBuilder.build_root("gori keylog off")
    keylog_callback?(Gori::Proxy::Tls::ContextFactory.server_context(leaf, key)).should be_false
  end

  it "prefers GORI_SSLKEYLOGFILE, creates it 0600 and logs TLS 1.3 secrets" do
    with_tempdir do |dir|
      path = File.join(dir, "gori.keys")
      other = File.join(dir, "browser.keys")
      KeyLog.configure({"GORI_SSLKEYLOGFILE" => path, "SSLKEYLOGFILE" => other})
        .should eq("TLS key log: writing session secrets to #{path}")
      KeyLog.active?.should be_true
      {% unless flag?(:win32) %}
        (File.info(path).permissions.value & 0o777).should eq(0o600)
      {% end %}

      keylog_handshake
      labels = File.read_lines(path).map(&.split(' ').first)
      labels.should contain("CLIENT_HANDSHAKE_TRAFFIC_SECRET")
      labels.should contain("SERVER_TRAFFIC_SECRET_0")
      labels.should contain("EXPORTER_SECRET")
    end
  end

  it "falls back to SSLKEYLOGFILE and logs CLIENT_RANDOM for TLS 1.2" do
    with_tempdir do |dir|
      path = File.join(dir, "keys")
      KeyLog.configure({"SSLKEYLOGFILE" => path}).should_not be_nil
      keylog_handshake(tls12: true)
      lines = File.read_lines(path)
      lines.size.should eq(1)
      lines[0].should match(/\ACLIENT_RANDOM [0-9a-f]{64} [0-9a-f]{96}\z/)
    end
  end

  it "lets an empty GORI_SSLKEYLOGFILE keep gori out of a browser's SSLKEYLOGFILE" do
    KeyLog.configure({"GORI_SSLKEYLOGFILE" => "", "SSLKEYLOGFILE" => "/nonexistent/keys"}).should be_nil
  end

  it "tightens an existing shared file to 0600" do
    posix_only!("POSIX permission bits")
    with_tempdir do |dir|
      path = File.join(dir, "browser.keys")
      File.write(path, "")
      File.chmod(path, 0o644)
      KeyLog.configure({"SSLKEYLOGFILE" => path})
      (File.info(path).permissions.value & 0o777).should eq(0o600)
    end
  end

  {% if flag?(:darwin) %}
    # `uappnd` allows the append but refuses the chmod, as another user's file would.
    it "refuses a file it cannot make private instead of writing secrets into it" do
      with_tempdir do |dir|
        path = File.join(dir, "shared.keys")
        File.write(path, "")
        File.chmod(path, 0o644)
        system("chflags", ["uappnd", path])
        begin
          KeyLog.configure({"SSLKEYLOGFILE" => path}).to_s.should contain("not private to you")
          KeyLog.active?.should be_false
        ensure
          system("chflags", ["nouappnd", path])
        end
      end
    end
  {% end %}

  it "refuses a path that is not a regular file" do
    with_tempdir do |dir|
      KeyLog.configure({"SSLKEYLOGFILE" => dir}).should eq("TLS key log: #{dir} is not a regular file; not logging")
      KeyLog.active?.should be_false
    end
  end

  it "stops logging on the first write error without raising" do
    KeyLog.reset(BrokenIO.new)
    KeyLog.append("CLIENT_RANDOM 00 00")
    KeyLog.active?.should be_false
  end

  it "installs on both upstream contexts when configured" do
    with_tempdir do |dir|
      KeyLog.configure({"SSLKEYLOGFILE" => File.join(dir, "keys")})
      # Distinct cache keys: a context cached earlier in the run was built with logging off.
      origin = Gori::Proxy::Upstream.context_for_policy(Gori::Settings::DEFAULT_OUTBOUND_TLS, verify: false, alpn: "keylog-spec")
      keylog_callback?(origin).should be_true
      keylog_callback?(Gori::Proxy::Upstream.proxy_tls_context(verify: false, ca: "keylog-spec")).should be_true
    end
  end
end
{% else %}
  describe KeyLog do
    it "reports an OpenSSL without the key log callback instead of failing to build" do
      KeyLog.available?.should be_false
      KeyLog.configure({"SSLKEYLOGFILE" => "/tmp/keys"}).not_nil!.should contain("cannot log keys")
    end
  end
{% end %}
