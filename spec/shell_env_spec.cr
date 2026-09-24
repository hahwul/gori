require "./spec_helper"
require "file_utils"

# `ShellEnv` is the engine behind `gori run shell` and the TUI's Open shell (#1238): the proxy
# variables, and a CA bundle that trusts gori's root WITHOUT dropping what the terminal already
# trusted. The bundle is the part that can go quietly wrong — most of the trust variables
# replace a tool's store rather than add to it — so most of what is pinned here is about it.

private def with_shell_fixture(&)
  root = File.tempname("gori-shell-env")
  Dir.mkdir_p(root)
  begin
    ca = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "ca"))
    system = File.join(root, "system.pem")
    other = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "other-ca"))
    File.write(system, "# system roots\n#{File.read(other.ca_cert_path)}")
    yield root, ca.ca_cert_path, system
  ensure
    FileUtils.rm_rf(root)
  end
end

private def build(root : String, ca : String, system : String?, env = {} of String => String,
                  keep_no_proxy = false, dir_source : String? = nil) : Gori::ShellEnv::Result
  Gori::ShellEnv.build("127.0.0.1:8070", ca, env: env, keep_no_proxy: keep_no_proxy,
    dir: File.join(root, "shell"), system_source: {system, dir_source})
end

private def value(result : Gori::ShellEnv::Result, name : String) : String?
  pair = result.vars.find { |(n, _)| n == name }
  raise "#{name} not in the result" unless pair
  pair[1]
end

private def has?(result : Gori::ShellEnv::Result, name : String) : Bool
  result.vars.any? { |(n, _)| n == name }
end

private def squash(s : String) : String
  s.delete(" \t\r\n")
end

describe Gori::ShellEnv do
  it "points every proxy variable at gori and unsets NO_PROXY, like the browser un-bypasses loopback" do
    with_shell_fixture do |root, ca, system|
      r = build(root, ca, system)
      Gori::ShellEnv::PROXY_VARS.each { |n| value(r, n).should eq("http://127.0.0.1:8070") }
      value(r, "NO_PROXY").should be_nil
      value(r, "no_proxy").should be_nil
      value(r, "GORI_SHELL").should eq("1")
      value(r, "GORI_PROXY").should eq("127.0.0.1:8070")
      value(r, "NODE_USE_ENV_PROXY").should eq("1")
      # ALL_PROXY is deliberately not touched either way.
      has?(r, "ALL_PROXY").should be_false
      r.proxy_url.should eq("http://127.0.0.1:8070")
    end
  end

  it "leaves an inherited NO_PROXY alone under keep_no_proxy" do
    with_shell_fixture do |root, ca, system|
      r = build(root, ca, system, keep_no_proxy: true)
      has?(r, "NO_PROXY").should be_false
      has?(r, "no_proxy").should be_false
    end
  end

  it "builds ONE bundle holding the system roots AND gori's root, for every replacing variable" do
    with_shell_fixture do |root, ca, system|
      r = build(root, ca, system)
      Gori::ShellEnv::BUNDLE_VARS.each { |n| value(r, n).should eq(r.bundle_path) }
      text = File.read(r.bundle_path)
      text.should start_with(File.read(system))
      squash(text).should contain(squash(File.read(ca).split("-----BEGIN CERTIFICATE-----")[1].split("-----END")[0]))
      File.dirname(r.bundle_path).should eq(File.join(root, "shell"))
      File.basename(r.bundle_path).should match(/\Aca-bundle-[0-9a-f]{16}\.pem\z/)
      File.info(r.bundle_path).permissions.value.should eq(0o644)
    end
  end

  it "gives NODE_EXTRA_CA_CERTS gori's root alone — Node appends it to its own roots" do
    with_shell_fixture do |root, ca, system|
      value(build(root, ca, system), "NODE_EXTRA_CA_CERTS").should eq(File.expand_path(ca))
    end
  end

  it "combines an inherited NODE_EXTRA_CA_CERTS with gori's root instead of replacing it" do
    with_shell_fixture do |root, ca, system|
      corp = File.join(root, "corp-extra.pem")
      File.write(corp, File.read(system))
      node = value(build(root, ca, system, {"NODE_EXTRA_CA_CERTS" => corp}), "NODE_EXTRA_CA_CERTS").not_nil!
      node.should_not eq(corp)
      File.basename(node).should start_with("node-extra-")
      text = File.read(node)
      text.should start_with(File.read(corp))
      squash(text).should contain(squash(File.read(ca).lines[1]))
    end
  end

  it "starts from the operator's own SSL_CERT_FILE (an enterprise bundle) rather than the OS roots" do
    with_shell_fixture do |root, ca, system|
      corp = File.join(root, "corp.pem")
      corp_ca = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "corp-ca"))
      File.write(corp, File.read(corp_ca.ca_cert_path))
      r = build(root, ca, system, {"SSL_CERT_FILE" => corp})
      File.read(r.bundle_path).should start_with(File.read(corp))
      File.read(r.bundle_path).should_not contain("# system roots")
      r.notes.should be_empty
    end
  end

  it "falls back to the OS roots, and says so, when the inherited SSL_CERT_FILE is unreadable" do
    with_shell_fixture do |root, ca, system|
      r = build(root, ca, system, {"SSL_CERT_FILE" => File.join(root, "missing.pem")})
      File.read(r.bundle_path).should start_with(File.read(system))
      r.notes.join.should contain("missing.pem")
    end
  end

  it "points at a store that already trusts gori's root instead of stacking another copy" do
    # The operator installed gori's CA into the bundle their SSL_CERT_FILE names.
    with_shell_fixture do |root, ca, system|
      trusted = File.join(root, "trusted.pem")
      File.write(trusted, File.read(system) + File.read(ca))
      build(root, ca, system, {"SSL_CERT_FILE" => trusted}).bundle_path.should eq(trusted)
    end
  end

  it "keeps a CA variable the terminal set for one tool, instead of handing it the shared bundle" do
    with_shell_fixture do |root, ca, system|
      corp = File.join(root, "requests-corp.pem")
      corp_ca = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "corp-ca"))
      File.write(corp, File.read(corp_ca.ca_cert_path))
      r = build(root, ca, system, {"REQUESTS_CA_BUNDLE" => corp})
      own = value(r, "REQUESTS_CA_BUNDLE").not_nil!
      own.should_not eq(r.bundle_path)
      File.read(own).should start_with(File.read(corp))
      squash(File.read(own)).should contain(squash(File.read(ca).lines[1]))
      value(r, "GIT_SSL_CAINFO").should eq(r.bundle_path) # the others are untouched by it
      value(r, "GORI_SHELL_ORIG_REQUESTS_CA_BUNDLE").should eq(corp)
    end
  end

  it "records what it replaces, so a gori inside the shell and a shell inside it can find it" do
    with_shell_fixture do |root, ca, system|
      r = build(root, ca, system, {"HTTPS_PROXY" => "http://corp.example:3128", "NO_PROXY" => ".internal"})
      value(r, "GORI_SHELL_ORIG_HTTPS_PROXY").should eq("http://corp.example:3128")
      value(r, "GORI_SHELL_ORIG_NO_PROXY").should eq(".internal")
      has?(r, "GORI_SHELL_ORIG_HTTP_PROXY").should be_false # nothing was there to record
      # Left alone under keep_no_proxy, so there is nothing to record either.
      kept = build(root, ca, system, {"NO_PROXY" => ".internal"}, keep_no_proxy: true)
      has?(kept, "GORI_SHELL_ORIG_NO_PROXY").should be_false
    end
  end

  it "restores NO_PROXY from the ORIG record inside a gori shell when keep_no_proxy is set" do
    with_shell_fixture do |root, ca, system|
      outer = build(root, ca, system, {"NO_PROXY" => "corp.internal", "HTTPS_PROXY" => "http://corp:3128"})
      inner_env = outer.to_env.compact.merge({"PATH" => "/usr/bin"})
      inner_env.has_key?("NO_PROXY").should be_false
      inner_env["GORI_SHELL_ORIG_NO_PROXY"].should eq("corp.internal")

      inner = build(root, ca, system, inner_env, keep_no_proxy: true)
      value(inner, "NO_PROXY").should eq("corp.internal")
      value(inner, "GORI_SHELL_ORIG_NO_PROXY").should eq("corp.internal")
    end
  end

  it "starts a shell inside a shell from the terminal's ORIGINAL trust, not the outer gori's root" do
    with_shell_fixture do |root, ca, system|
      outer = build(root, ca, system, {"HTTPS_PROXY" => "http://corp.example:3128"})
      inner_env = outer.to_env.compact.merge({"PATH" => "/usr/bin"})
      # The inner shell points at ANOTHER gori, with its own CA.
      other = Gori::Proxy::Tls::CertAuthority.load_or_create(File.join(root, "second-ca"))
      inner = Gori::ShellEnv.build("127.0.0.1:9090", other.ca_cert_path, env: inner_env,
        dir: File.join(root, "shell"), system_source: {system, nil})
      text = squash(File.read(inner.bundle_path))
      text.should contain(squash(File.read(other.ca_cert_path).lines[1]))
      text.should_not contain(squash(File.read(ca).lines[1])) # no stale MITM root from the outer gori
      value(inner, "NODE_EXTRA_CA_CERTS").should eq(File.expand_path(other.ca_cert_path))
      # The record still describes the terminal before the FIRST shell.
      value(inner, "GORI_SHELL_ORIG_HTTPS_PROXY").should eq("http://corp.example:3128")
      value(inner, "GORI_PROXY").should eq("127.0.0.1:9090")
    end
  end

  it "names what is wrong with a CA before anything is built" do
    with_shell_fixture do |root, ca, _system|
      Gori::ShellEnv.ca_problem(ca).should be_nil
      Gori::ShellEnv.ca_problem(File.join(root, "nope.pem")).not_nil!.should contain("cannot read")
      File.write(File.join(root, "junk.pem"), "-----BEGIN CERTIFICATE-----\n")
      Gori::ShellEnv.ca_problem(File.join(root, "junk.pem")).not_nil!.should contain("no PEM certificate")
    end
  end

  it "names the bundle by its content, so the same inputs find the same file and a new CA a new one" do
    with_shell_fixture do |root, ca, system|
      first = build(root, ca, system)
      mtime = File.info(first.bundle_path).modification_time
      again = build(root, ca, system)
      again.bundle_path.should eq(first.bundle_path)
      File.info(again.bundle_path).modification_time.should eq(mtime) # not rewritten
      # `gori ca regenerate` in place: same path, new root → a new bundle, never the stale one.
      Gori::Proxy::Tls::CertAuthority.regenerate_at(File.dirname(ca))
      rotated = build(root, ca, system)
      rotated.bundle_path.should_not eq(first.bundle_path)
      squash(File.read(rotated.bundle_path)).should contain(squash(File.read(ca).lines[1]))
    end
  end

  it "assembles the base from a hashed-certificate directory when the system has no bundle file" do
    with_shell_fixture do |root, ca, system|
      certs = File.join(root, "certs")
      Dir.mkdir_p(certs)
      File.write(File.join(certs, "a.pem"), File.read(system))
      File.symlink(File.join(certs, "a.pem"), File.join(certs, "abcd1234.0")) # the same cert twice
      File.write(File.join(certs, "README"), "not a certificate")
      r = build(root, ca, nil, dir_source: certs)
      text = File.read(r.bundle_path)
      text.scan("-----BEGIN CERTIFICATE-----").size.should eq(2) # the system cert once, plus gori's
      text.should_not contain("not a certificate")
    end
  end

  it "trusts only gori's root, and says what that breaks, when no system store exists" do
    with_shell_fixture do |root, ca, _system|
      r = build(root, ca, nil)
      File.read(r.bundle_path).scan("-----BEGIN CERTIFICATE-----").size.should eq(1)
      r.notes.join.should contain("no system CA bundle")
    end
  end

  it "refuses a CA it cannot read rather than exporting a bundle that trusts nothing of gori's" do
    with_shell_fixture do |root, _ca, system|
      expect_raises(Gori::ShellEnv::Error, /cannot read gori's CA certificate/) do
        build(root, File.join(root, "nope.pem"), system)
      end
    end
  end

  describe "GODEBUG" do
    it "opts Go into SSL_CERT_FILE on macOS, whatever the program's go.mod says" do
      with_shell_fixture do |root, ca, system|
        value(build(root, ca, system), "GODEBUG").should eq("x509sslcertoverrideplatform=1")
      end
    end

    it "appends to an inherited GODEBUG" do
      with_shell_fixture do |root, ca, system|
        value(build(root, ca, system, {"GODEBUG" => "http2client=0"}), "GODEBUG")
          .should eq("http2client=0,x509sslcertoverrideplatform=1")
      end
    end

    it "leaves an explicit choice of the same key alone" do
      with_shell_fixture do |root, ca, system|
        r = build(root, ca, system, {"GODEBUG" => "x509sslcertoverrideplatform=0"})
        has?(r, "GODEBUG").should be_false
      end
    end
  end

  describe ".dial_authority" do
    it "turns a wildcard bind into loopback of the same family and brackets IPv6" do
      Gori::ShellEnv.dial_authority("0.0.0.0", 8070).should eq("127.0.0.1:8070")
      Gori::ShellEnv.dial_authority("::", 8070).should eq("[::1]:8070")
      Gori::ShellEnv.dial_authority("::1", 9000).should eq("[::1]:9000")
      Gori::ShellEnv.dial_authority("10.0.0.5", 8080).should eq("10.0.0.5:8080")
    end
  end

  describe ".render" do
    it "writes export/unset lines for POSIX shells and set -gx/-e for fish, header as comments" do
      with_shell_fixture do |root, ca, system|
        r = build(root, ca, system)
        sh = Gori::ShellEnv.render(r, Gori::ShellEnv::Syntax::Posix, header: ["line one"])
        sh.lines.first.should eq("# line one")
        sh.should contain("export HTTPS_PROXY='http://127.0.0.1:8070'\n")
        sh.should contain("unset NO_PROXY\n")
        fish = Gori::ShellEnv.render(r, Gori::ShellEnv::Syntax::Fish)
        fish.should contain("set -gx HTTPS_PROXY 'http://127.0.0.1:8070'\n")
        fish.should contain("set -e NO_PROXY\n")
        fish.should_not contain("#")
      end
    end

    it "sanitizes comment lines so control characters and newlines cannot escape comments" do
      with_shell_fixture do |root, ca, system|
        r = build(root, ca, system)
        sh = Gori::ShellEnv.render(r, Gori::ShellEnv::Syntax::Posix,
          header: ["line\nwith\rnewlines\x00and\x1bescapes"])
        # Each header element must remain exactly one comment line
        sh.lines.first.should eq("# line with newlines and escapes")
      end
    end

    it "replaces ASCII control characters with spaces in sanitize_comment" do
      Gori::ShellEnv.sanitize_comment("hello\nworld\r\x00\x1b\x7f!").should eq("hello world    !")
    end

    # The values are paths, and a home directory can hold anything a filename can.
    it "quotes a value so the shell reads it back byte for byte" do
      nasty = %(/tmp/it's a "path" with $HOME and `x` \\ and \\' and ${Y})
      file = File.tempname("gori-shell-quote")
      begin
        File.write(file, "X=#{Gori::ShellEnv.posix_quote(nasty)}\n")
        out = Process.run("/bin/sh", ["-c", %(. "$0"; printf %s "$X"), file],
          output: Process::Redirect::Pipe) { |p| p.output.gets_to_end }
        out.should eq(nasty)
        if fish = Process.find_executable("fish")
          File.write(file, "set -l X #{Gori::ShellEnv.fish_quote(nasty)}\nprintf %s $X\n")
          out = Process.run(fish, [file], output: Process::Redirect::Pipe) { |p| p.output.gets_to_end }
          out.should eq(nasty)
        end
      ensure
        File.delete?(file)
      end
    end
  end

  describe "Syntax" do
    it "maps every POSIX-family name to one syntax and fish to its own" do
      %w[sh bash zsh ksh dash posix SH].each { |n| Gori::ShellEnv::Syntax.parse?(n).should eq(Gori::ShellEnv::Syntax::Posix) }
      Gori::ShellEnv::Syntax.parse?("fish").should eq(Gori::ShellEnv::Syntax::Fish)
      Gori::ShellEnv::Syntax.parse?("pwsh").should be_nil
      Gori::ShellEnv::Syntax.for_shell("/opt/homebrew/bin/fish").should eq(Gori::ShellEnv::Syntax::Fish)
      Gori::ShellEnv::Syntax.for_shell("/bin/zsh").should eq(Gori::ShellEnv::Syntax::Posix)
      Gori::ShellEnv::Syntax.for_shell(nil).should eq(Gori::ShellEnv::Syntax::Posix)
    end
  end

  describe ".inherited_proxy" do
    it "reads the live value, skips the shell's own, and falls back to what the shell replaced" do
      Gori::ShellEnv.inherited_proxy("HTTPS_PROXY", {"HTTPS_PROXY" => "http://corp:3128"}).should eq("http://corp:3128")
      shell = {"GORI_SHELL" => "1", "GORI_PROXY" => "127.0.0.1:8070", "HTTPS_PROXY" => "http://127.0.0.1:8070"}
      Gori::ShellEnv.inherited_proxy("HTTPS_PROXY", shell).should be_nil
      Gori::ShellEnv.inherited_proxy("HTTPS_PROXY", shell.merge({"GORI_SHELL_ORIG_HTTPS_PROXY" => "http://corp:3128"}))
        .should eq("http://corp:3128")
      # Outside a shell a stray record means nothing.
      Gori::ShellEnv.inherited_proxy("NO_PROXY", {"GORI_SHELL_ORIG_NO_PROXY" => ".x"}).should be_nil
    end
  end

  describe ".injected_proxy?" do
    it "recognises only the exact proxy a gori shell exported" do
      env = {"GORI_SHELL" => "1", "GORI_PROXY" => "127.0.0.1:8070"}
      Gori::ShellEnv.injected_proxy?("http://127.0.0.1:8070", env).should be_true
      Gori::ShellEnv.injected_proxy?("HTTP://127.0.0.1:8070/", env).should be_true
      Gori::ShellEnv.injected_proxy?("127.0.0.1:8070", env).should be_true
      Gori::ShellEnv.injected_proxy?("http://127.0.0.1:8071", env).should be_false
      Gori::ShellEnv.injected_proxy?("http://corp.example:3128", env).should be_false
      # Without the marker the same value is just a proxy the operator exported.
      Gori::ShellEnv.injected_proxy?("http://127.0.0.1:8070", {"GORI_PROXY" => "127.0.0.1:8070"}).should be_false
      Gori::ShellEnv.injected_proxy?("http://127.0.0.1:8070", {"GORI_SHELL" => "1"}).should be_false
    end
  end
end
