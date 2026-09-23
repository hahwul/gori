require "../spec_helper"
require "file_utils"
require "socket"

# A `gori mcp` server lives for hours next to a TUI and `gori run` in the operator's terminal, and
# every one of them edits the same settings.json and project rows. What these pin is that the
# server's NEXT call sees a peer's edit — above all on the send path, where a stale copy means a
# credential the operator rotated or deleted keeps going out:
#
#   * #1216 — the session-slot list (`Env.overlay_slot`'s input), a project row;
#   * #1217 — the global `$KEY` table in settings.json;
#   * #1218 — the `$GEN.USER_AGENT` corpus in settings.json;
#   * #1215 — the global saved-view library in settings.json (a read, not a send).
#
# Driven through a real `Gori::MCP::Tools` against a loopback origin that records one header.

private def with_peer_home(&)
  snapshot = Gori::Settings.export_document(Gori::Settings::SECTION_KEYS)
  prev_home = ENV["GORI_HOME"]?
  prev_cfg = ENV["GORI_CONFIG"]?
  dir = File.tempname("gori-mcp-peer-settings")
  Dir.mkdir_p(dir)
  begin
    ENV["GORI_HOME"] = dir
    ENV.delete("GORI_CONFIG")
    Gori::Settings.path_override = nil
    Gori::Settings.forget_reloaded_sections
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.user_agents = [] of String
    Gori::Settings.saved_views = [] of Gori::Settings::SavedView
    yield File.join(dir, "settings.json")
  ensure
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.user_agents = [] of String
    Gori::Settings.saved_views = [] of Gori::Settings::SavedView
    Gori::Settings.path_override = nil
    ENV["GORI_HOME"] = dir
    File.write(File.join(dir, "settings.json"), snapshot)
    Gori::Settings.load
    Gori::Settings.forget_reloaded_sections
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    prev_cfg ? (ENV["GORI_CONFIG"] = prev_cfg) : ENV.delete("GORI_CONFIG")
    FileUtils.rm_rf(dir)
  end
end

# One request per connection; the value of `header` (nil when absent) goes down the channel.
private def header_origin(header : String) : {TCPServer, Channel(String?)}
  server = TCPServer.new("127.0.0.1", 0)
  seen = Channel(String?).new(8)
  spawn do
    while conn = server.accept?
      spawn_with(conn) do |c|
        c.read_timeout = 5.seconds
        head = Gori::Proxy::Codec::Http1.read_head(c)
        value = head.try do |h|
          String.new(h).each_line
            .find(&.downcase.starts_with?("#{header.downcase}:"))
            .try(&.split(':', 2)[1].strip)
        end
        seen.send(value)
        c << "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        c.flush
      rescue
      ensure
        c.close
      end
    end
  end
  {server, seen}
end

private def send_to(tools, port : Int32, headers : String) : Gori::MCP::Tools::Result
  tools.call("send_request", JSON.parse(
    %({"url":"http://127.0.0.1:#{port}/","headers":#{headers},"allow_unscoped":true,"record_history":false})))
end

private def sent(tools, port : Int32, headers : String, seen : Channel(String?)) : String?
  r = send_to(tools, port, headers)
  fail "send_request errored: #{r.text}" if r.is_error
  receive_within(seen, 5, "the origin's header")
end

describe "MCP follows a peer's settings between calls" do
  it "stops overlaying a session slot a peer deleted (#1216)" do
    with_store_env do |store|
      server, seen = header_origin("X-Identity")
      begin
        Gori::SessionSlots.load(store).add(Gori::SessionSlot.new("admin", [{"X-Identity", "old"}]))
        tools = tools_for(store)
        tools.call("set_active_session_slot", JSON.parse(%({"name":"admin"}))).is_error.should be_false
        sent(tools, server.local_address.port, "{}", seen).should eq("old")

        # `gori run session rm admin` in another terminal: a different registry, the same row.
        Gori::SessionSlots.load(store).remove("admin").should be_true
        sent(tools, server.local_address.port, "{}", seen).should be_nil
      ensure
        server.close
      end
    end
  end

  it "sends a global $KEY a peer rotated, and stops sending one it deleted (#1217)" do
    with_peer_home do |path|
      with_env_syntax(Gori::Env::Syntax::Bare) do
        with_store_env do |store|
          server, seen = header_origin("X-Token")
          begin
            File.write(path, %({"env":{"syntax":"bare","vars":[{"key":"TOKEN","value":"old"}]}}))
            tools = tools_for(store)
            port = server.local_address.port
            sent(tools, port, %({"X-Token":"$TOKEN"}), seen).should eq("old")

            # A different LENGTH as well as a different value: `reload_section` skips a file whose
            # (mtime, size) has not moved, and a coarse-mtime filesystem can stamp both writes alike.
            File.write(path, %({"env":{"syntax":"bare","vars":[{"key":"TOKEN","value":"rotated"}]}}))
            sent(tools, port, %({"X-Token":"$TOKEN"}), seen).should eq("rotated")

            # The last var deleted: `serialize_env` omits `vars` entirely.
            File.write(path, %({"env":{"syntax":"bare"}}))
            r = send_to(tools, port, %({"X-Token":"$TOKEN"}))
            Gori::Env.effective_vars.has_key?("TOKEN").should be_false
            # Refused as unresolved or sent literal — either way, never the deleted value.
            (r.is_error ? nil : receive_within(seen, 5, "the origin's header")).should_not eq("old")
          ensure
            server.close
          end
        end
      end
    end
  end

  it "mints $GEN.USER_AGENT from a corpus a peer set (#1218)" do
    with_peer_home do |path|
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        with_store_env do |store|
          server, seen = header_origin("User-Agent")
          begin
            File.write(path, %({"env":{"syntax":"namespaced"}}))
            tools = tools_for(store)
            port = server.local_address.port
            sent(tools, port, %({"User-Agent":"$GEN.USER_AGENT"}), seen).should_not eq("Peer-UA/1")

            File.write(path, %({"env":{"syntax":"namespaced"},"user_agents":["Peer-UA/1"]}))
            sent(tools, port, %({"User-Agent":"$GEN.USER_AGENT"}), seen).should eq("Peer-UA/1")
            JSON.parse(tools.call("list_env", JSON.parse("{}")).text)["user_agents"]["source"].as_s
              .should eq("settings")
          ensure
            server.close
          end
        end
      end
    end
  end

  it "resolves a global view a peer added (#1215)" do
    with_peer_home do |path|
      with_store do |store|
        tools = tools_for(store)
        tools.call("list_history", JSON.parse(%({"view":"peer-view"}))).is_error.should be_true

        File.write(path, %({"saved_views":{"next_view_id":2,"views":[{"id":1,"name":"peer-view","query":"status:>=400"}]}}))
        tools.call("list_history", JSON.parse(%({"view":"peer-view"}))).is_error.should be_false
        listed = JSON.parse(tools.call("list_views", JSON.parse(%({"scope":"global"}))).text)
        listed["views"].as_a.map(&.["name"].as_s).should eq(["peer-view"])
      end
    end
  end
end
