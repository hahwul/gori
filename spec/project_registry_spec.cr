require "./spec_helper"
require "file_utils"

private def with_root(&)
  root = File.tempname("gori-projects")
  begin
    yield root
  ensure
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

describe Gori::ProjectRegistry do
  it "creates a named project with a slugified directory" do
    with_root do |root|
      reg = Gori::ProjectRegistry.new(root)
      p = reg.create("ACME Red Team!")
      p.name.should eq("ACME Red Team!") # display name preserved
      p.db_path.should eq(File.join(root, "acme-red-team", "gori.db"))
      Dir.exists?(p.dir).should be_true
      p.ephemeral?.should be_false
    end
  end

  it "lists created projects (and ignores temp/hidden dirs)" do
    with_root do |root|
      reg = Gori::ProjectRegistry.new(root)
      a = reg.create("alpha")
      Gori::Store.open(a.db_path).close # give it a real DB file so it lists
      reg.temp("xyz")                   # hidden temp dir, must not be listed

      names = reg.list.map(&.name)
      names.should contain("alpha")
      names.should_not contain("temp")
    end
  end

  it "makes temp projects ephemeral and cleans them up" do
    with_root do |root|
      reg = Gori::ProjectRegistry.new(root)
      t = reg.temp("tok123")
      t.ephemeral?.should be_true
      Dir.exists?(t.dir).should be_true
      t.cleanup
      Dir.exists?(t.dir).should be_false
    end
  end

  it "deletes a project from disk" do
    with_root do |root|
      reg = Gori::ProjectRegistry.new(root)
      p = reg.create("doomed")
      Gori::Store.open(p.db_path).close
      reg.delete(p)
      Dir.exists?(p.dir).should be_false
      reg.list.map(&.name).should_not contain("doomed")
    end
  end
end

describe Gori::Session do
  it "opens a project store + proxy and captures, then cleans up a temp project" do
    with_root do |root|
      ca_dir = File.join(root, "ca")
      ca = Gori::Proxy::Tls::CertAuthority.load_or_create(ca_dir)
      registry = Gori::Verbs.registry
      config = Gori::Config.new(listen: "127.0.0.1", port: 0)
      project = Gori::ProjectRegistry.new(root).temp("sess")

      session = Gori::Session.open(config, ca, registry, project)
      session.capturing?.should be_true
      session.proxy.port.should be > 0
      session.store.count.should eq(0)
      dir = project.dir
      session.close # stops proxy, closes store, removes temp dir
      Dir.exists?(dir).should be_false
    end
  end
end
