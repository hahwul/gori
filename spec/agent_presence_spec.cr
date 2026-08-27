require "./spec_helper"
require "../src/gori/agent_presence"
require "file_utils"

private def with_project(&)
  root = File.tempname("gori-agent-presence")
  begin
    registry = Gori::ProjectRegistry.new(root)
    yield registry, registry.create("target")
  ensure
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def announce(db_path : String, client : String? = "claude-code",
                     version : String? = "1.0", read_only : Bool = false,
                     source : String? = "workspace-created") : Gori::AgentPresence
  Gori::AgentPresence.announce(db_path, client: client, client_version: version,
    read_only: read_only, selection_source: source).not_nil!
end

# Does chmod actually bite here? Root (and some CI filesystems) ignore it, and the
# unwritable-directory example would then assert a failure that cannot happen.
private def mode_enforced?(dir : String) : Bool
  probe = File.join(dir, ".gori-perm-probe")
  File.write(probe, "x")
  File.delete?(probe)
  false
rescue
  true
end

# `gori mcp` attached to a project is invisible today — no lock names its holder, no file says
# an agent is there. AgentPresence is the flock+sidecar marker the TUI and picker read (#815):
# the flock is the truth about liveness (SIGKILL frees it, an ensure never runs), the JSON is
# decoration.
describe Gori::AgentPresence do
  it "announces one live entry with the fields it was given" do
    with_project do |_registry, project|
      presence = announce(project.db_path, client: "claude-code", version: "2.1.0",
        read_only: false, source: "workspace-created")
      begin
        entries = Gori::AgentPresence.live(project.db_path)
        entries.size.should eq(1)
        e = entries.first
        e.kind.should eq(Gori::AgentPresence::KIND_MCP)
        e.client.should eq("claude-code")
        e.client_version.should eq("2.1.0")
        e.pid.should eq(Process.pid.to_i64)
        e.read_only.should be_false
        e.selection_source.should eq("workspace-created")
        e.attached_at.should_not be_nil
        # Keyed beside the database, like the open lock — the picker only ever has paths.
        File.dirname(e.path).should eq("#{Gori::Paths.canonical_file(project.db_path)}.agents")
      ensure
        presence.close
      end
    end
  end

  it "close removes the marker and empties live" do
    with_project do |_registry, project|
      presence = announce(project.db_path)
      path = Gori::AgentPresence.live(project.db_path).first.path
      presence.close
      Gori::AgentPresence.live(project.db_path).should be_empty
      File.exists?(path).should be_false
      presence.close # idempotent — release_presence and a server ensure may both run
    end
  end

  it "stacks two attachments oldest-first, and one close leaves the other" do
    with_project do |_registry, project|
      a = announce(project.db_path, client: "first")
      sleep 5.milliseconds # attached_at_ms has millisecond grain; keep the order observable
      b = announce(project.db_path, client: "second")
      begin
        Gori::AgentPresence.live(project.db_path).map(&.client).should eq(["first", "second"])
        a.close
        Gori::AgentPresence.live(project.db_path).map(&.client).should eq(["second"])
      ensure
        a.close
        b.close
      end
      Gori::AgentPresence.live(project.db_path).should be_empty
    end
  end

  it "sweeps a marker whose owner is gone" do
    with_project do |_registry, project|
      # A SIGKILL'd server leaves exactly this: a well-formed JSON file with no lock held.
      # The file's existence must never read as presence — only a held flock does.
      dir = Gori::AgentPresence.dir_for(project.db_path)
      Dir.mkdir_p(dir)
      stale = File.join(dir, "99999-deadbeef.json")
      File.write(stale, {kind: "mcp", client: "ghost", pid: 99999_i64}.to_json)
      Gori::AgentPresence.live(project.db_path).should be_empty
      File.exists?(stale).should be_false # swept, so the dir cannot fill with corpses
    end
  end

  it "counts live attachments without reading their bodies, and sweeps stale ones too" do
    with_project do |_registry, project|
      # The picker's cheaper probe: same liveness + stale sweep as `live`, no body parse.
      Gori::AgentPresence.count(project.db_path).should eq(0)
      a = announce(project.db_path, client: "first")
      b = announce(project.db_path, client: "second")
      begin
        Gori::AgentPresence.count(project.db_path).should eq(2)
        # A corrupt body still COUNTS — the lock, not the JSON, is what says someone is here.
        File.write(Gori::AgentPresence.live(project.db_path).first.path, "{ not json")
        Gori::AgentPresence.count(project.db_path).should eq(2)
      ensure
        a.close
        b.close
      end
      # And it sweeps a dead marker just like `live` does.
      dir = Gori::AgentPresence.dir_for(project.db_path)
      stale = File.join(dir, "99999-deadbeef.json")
      File.write(stale, {kind: "mcp", pid: 99999_i64}.to_json)
      Gori::AgentPresence.count(project.db_path).should eq(0)
      File.exists?(stale).should be_false
    end
  end

  it "ignores dot-prefixed temp files without sweeping them" do
    with_project do |_registry, project|
      dir = Gori::AgentPresence.dir_for(project.db_path)
      Dir.mkdir_p(dir)
      tmp = File.join(dir, ".12345-abcd.json.tmp")
      File.write(tmp, "half-written")
      Gori::AgentPresence.live(project.db_path).should be_empty
      File.exists?(tmp).should be_true # in-flight — its writer still has it
    end
  end

  it "reads a corrupted live marker as attached-but-unnamed" do
    with_project do |_registry, project|
      presence = announce(project.db_path, client: "claude-code")
      begin
        # flock is advisory: anyone can truncate the body out from under the holder. The
        # lock still says someone is here, so the row demotes to nameless, never to absent.
        path = Gori::AgentPresence.live(project.db_path).first.path
        File.write(path, "{ not json")
        entries = Gori::AgentPresence.live(project.db_path)
        entries.size.should eq(1)
        entries.first.client.should be_nil
      ensure
        presence.close
      end
    end
  end

  it "update rewrites the body in place, keeping the same marker file" do
    with_project do |_registry, project|
      # The handshake arrives AFTER the bind announces, so the name is filled in later. It
      # must not go through a temp+rename — that swaps the inode and the flock stays on the
      # old one, leaving the visible file unlocked (a reader would sweep it as stale).
      presence = announce(project.db_path, client: nil, version: nil)
      begin
        before = Gori::AgentPresence.live(project.db_path).first
        before.client.should be_nil
        presence.update("claude-code", "9.9")
        after = Gori::AgentPresence.live(project.db_path).first
        after.client.should eq("claude-code")
        after.client_version.should eq("9.9")
        after.path.should eq(before.path)
      ensure
        presence.close
      end
    end
  end

  it "keys on the canonicalized database, so two spellings share one marker directory" do
    real = File.tempname("gori-agents-real")
    link = File.tempname("gori-agents-link")
    Dir.mkdir_p(File.join(real, "projects", "api"))
    File.symlink(real, link)
    begin
      through_link = File.join(link, "projects", "api", Gori::Project::DB_FILE)
      through_real = File.join(real, "projects", "api", Gori::Project::DB_FILE)
      # `--db` takes what the operator typed; the registry builds from `$GORI_HOME` as given.
      # One database with two marker dirs means a TUI probing the wrong one shows no agent.
      presence = announce(through_link)
      begin
        Gori::AgentPresence.dir_for(through_link).should eq(Gori::AgentPresence.dir_for(through_real))
        Gori::AgentPresence.live(through_real).size.should eq(1)
      ensure
        presence.close
      end
      Gori::AgentPresence.live(through_real).should be_empty
    ensure
      File.delete?(link)
      FileUtils.rm_rf(real)
    end
  end

  it "degrades to no marker on an unwritable directory instead of raising" do
    with_project do |_registry, project|
      # A `--db` under a directory gori cannot write must not kill the MCP server — presence
      # is decoration, the session is the product.
      File.chmod(project.dir, 0o500)
      begin
        if mode_enforced?(project.dir)
          Gori::AgentPresence.announce(project.db_path, client: "c", client_version: nil,
            read_only: false, selection_source: nil).should be_nil
          Gori::AgentPresence.live(project.db_path).should be_empty
        end
      ensure
        File.chmod(project.dir, 0o700) rescue nil
      end
    end
  end

  it "answers nothing for :memory: and the empty path" do
    Gori::AgentPresence.announce(":memory:", client: "c", client_version: nil,
      read_only: false, selection_source: nil).should be_nil
    Gori::AgentPresence.live(":memory:").should be_empty
    Gori::AgentPresence.announce("", client: "c", client_version: nil,
      read_only: false, selection_source: nil).should be_nil
    Gori::AgentPresence.live("").should be_empty
  end
end
