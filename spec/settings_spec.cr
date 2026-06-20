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
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
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
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.bind_host = "127.0.0.1"
      Gori::Settings.bind_port = 8070
      Gori::Settings.upstream_proxy = ""
    end
  end

  it "keeps defaults on a missing/garbled settings file" do
    dir = File.tempname("gori-settings-empty")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.bind_port = 7000
      Gori::Settings.load # no file → unchanged
      Gori::Settings.bind_port.should eq(7000)
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.bind_port = 8070
    end
  end

  describe ".editor_command" do
    it "splits a configured command into program + args" do
      Gori::Settings.editor = "code --wait"
      Gori::Settings.editor_command.should eq(["code", "--wait"])
    ensure
      Gori::Settings.editor = ""
    end

    it "falls back to $VISUAL → $EDITOR → vi when unset" do
      Gori::Settings.editor = ""
      v = ENV["VISUAL"]?; e = ENV["EDITOR"]?
      begin
        ENV["VISUAL"] = "nvim"
        Gori::Settings.editor_command.should eq(["nvim"])
        ENV.delete("VISUAL"); ENV["EDITOR"] = "nano"
        Gori::Settings.editor_command.should eq(["nano"])
        ENV.delete("EDITOR")
        Gori::Settings.editor_command.should eq(["vi"])
      ensure
        v ? (ENV["VISUAL"] = v) : ENV.delete("VISUAL")
        e ? (ENV["EDITOR"] = e) : ENV.delete("EDITOR")
      end
    end
  end

  it "round-trips the editor command + loads it even with no network block" do
    dir = File.tempname("gori-settings-ed")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.editor = "vim -u NONE"
      Gori::Settings.save.should be_true
      Gori::Settings.editor = "" # clear, then reload from disk
      Gori::Settings.load
      Gori::Settings.editor.should eq("vim -u NONE")

      # regression: an editor-only file (no "network" block) still loads the editor
      File.write(Gori::Settings.path, %({"editor":{"command":"emacs -nw"}}))
      Gori::Settings.editor = ""
      Gori::Settings.load
      Gori::Settings.editor.should eq("emacs -nw")
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.editor = ""
    end
  end
end
