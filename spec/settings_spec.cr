require "./spec_helper"
require "file_utils"

describe Gori::Settings do
  describe ".upstream_proxy_addr" do
    it "returns nil when unset/blank" do
      Gori::Settings.upstream_proxy = "  "
      Gori::Settings.upstream_proxy_addr.should be_nil
    ensure
      Gori::Settings.upstream_proxy = ""
    end

    it "parses host:port" do
      Gori::Settings.upstream_proxy = "127.0.0.1:8080"
      Gori::Settings.upstream_proxy_addr.should eq({"127.0.0.1", 8080})
    ensure
      Gori::Settings.upstream_proxy = ""
    end

    it "strips an http:// scheme + trailing slash" do
      Gori::Settings.upstream_proxy = "http://proxy.local:3128/"
      Gori::Settings.upstream_proxy_addr.should eq({"proxy.local", 3128})
    ensure
      Gori::Settings.upstream_proxy = ""
    end

    it "defaults the port to 8080 when omitted" do
      Gori::Settings.upstream_proxy = "proxy.local"
      Gori::Settings.upstream_proxy_addr.should eq({"proxy.local", 8080})
    ensure
      Gori::Settings.upstream_proxy = ""
    end
  end

  it "persists and reloads the network settings as JSON" do
    dir = File.tempname("gori-settings")
    Dir.mkdir_p(dir)
    prev = ENV["XDG_CONFIG_HOME"]?
    begin
      ENV["XDG_CONFIG_HOME"] = dir
      Gori::Settings.bind_host = "0.0.0.0"
      Gori::Settings.bind_port = 9999
      Gori::Settings.upstream_proxy = "up:1234"
      Gori::Settings.save.should be_true

      Gori::Settings.bind_host = "x"
      Gori::Settings.bind_port = 1
      Gori::Settings.upstream_proxy = ""
      Gori::Settings.load
      Gori::Settings.bind_host.should eq("0.0.0.0")
      Gori::Settings.bind_port.should eq(9999)
      Gori::Settings.upstream_proxy.should eq("up:1234")
    ensure
      prev ? (ENV["XDG_CONFIG_HOME"] = prev) : ENV.delete("XDG_CONFIG_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.bind_host = "127.0.0.1"
      Gori::Settings.bind_port = 8070
      Gori::Settings.upstream_proxy = ""
    end
  end

  it "keeps defaults on a missing/garbled settings file" do
    dir = File.tempname("gori-settings-empty")
    Dir.mkdir_p(dir)
    prev = ENV["XDG_CONFIG_HOME"]?
    begin
      ENV["XDG_CONFIG_HOME"] = dir
      Gori::Settings.bind_port = 7000
      Gori::Settings.load # no file → unchanged
      Gori::Settings.bind_port.should eq(7000)
    ensure
      prev ? (ENV["XDG_CONFIG_HOME"] = prev) : ENV.delete("XDG_CONFIG_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.bind_port = 8070
    end
  end
end
