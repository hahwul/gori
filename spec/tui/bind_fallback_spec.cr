require "../spec_helper"

include Gori::Tui

# A startup PORT FALLBACK — the configured bind port was already taken, so the proxy came up
# on a different one — is an environmental accident, and `Runner#run` used to write it back
# into configuration:
#
#   if Settings.project_bind_port
#     Settings.project_bind_port = @session.proxy.port   # → the project DB
#   else
#     Settings.bind_port = @session.proxy.port           # → the persisted global
#   end
#
# Both branches destroyed the port the operator deliberately pinned. Via the PROJECT layer,
# because `ProjectView#load_settings_values` seeds its dirty BASELINE from `effective_*` and
# `ProjectController#commit_project_network` writes all six network fields whenever any ONE of
# them is dirty — so editing the idle timeout silently re-pinned the fallback port. Via the
# GLOBAL layer, because `Settings.bind_port` is what `Settings.save` serializes into
# settings.json on every unrelated save (the pet toggle, tabs, hotkeys, env), which the NEXT
# project then inherits: a cross-project write.
#
# `Runner.port_fallback` is the seam that reaction now runs through, so the examples below
# call it exactly where the shell does. The FIRST one is the end-to-end statement — a real
# `ProjectView` over a real store — and is what actually catches a reintroduction; the rest
# pin the seam's own boundaries.
#
# NOT asserted here: the rebind itself. `Runner` needs a live tty, so `apply_settings` is
# represented by its extracted predicate (`port_fallback_stands?`) rather than driven.

private def tmp_store(&)
  path = File.tempname("gori-bindfb", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# `Gori::Settings` is process-global class state SHARED with every other spec file, so each
# example restores the same baseline `project_view_spec.cr` assumes — on both sides, since a
# leaked project override would silently flip an example over there depending on file order.
private def reset_projnet
  Gori::Settings.project_bind_host = nil
  Gori::Settings.project_bind_port = nil
  Gori::Settings.project_upstream_proxy = nil
  Gori::Settings.project_connect_timeout_secs = nil
  Gori::Settings.project_io_timeout_secs = nil
  Gori::Settings.project_capture_max_mib = nil
  Gori::Settings.bind_host = "127.0.0.1"
  Gori::Settings.bind_port = 8070
  Gori::Settings.upstream_proxy = ""
end

describe "startup port fallback" do
  it "leaves a PROJECT pin pinned, so editing another network field cannot re-pin the fallback" do
    tmp_store do |store|
      reset_projnet
      # The operator pinned 8080 for this project (global stays 8070).
      store.set_setting(Gori::Settings::PROJECT_BIND_PORT_KEY, "8080")
      Gori::Settings.load_project_network(store, bind: true)
      Gori::Settings.project_bind_port.should eq(8080)

      # …and something else already held 8080, so the proxy came up on 8081.
      Runner.port_fallback(8080, 8081).should eq({8080, 8081})

      # Neither configuration layer moved. This is the invariant; everything below is its
      # consequence for the operator.
      Gori::Settings.project_bind_port.should eq(8080)
      Gori::Settings.bind_port.should eq(8070)
      store.setting(Gori::Settings::PROJECT_BIND_PORT_KEY).should eq("8080")

      # The Project SETTINGS pane is an editor for the PIN, and `Runner#run` reloads it right
      # after reacting to the bind outcome.
      view = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
      view.refresh_settings
      view.settings_values[1].should eq("8080") # the pin, not the port we happen to be on
      view.settings_dirty?.should be_false      # an untouched pane has nothing to commit

      # Now the operator edits ONLY the idle timeout. `commit_project_network` hands
      # `apply_project_network` all six fields, so whatever sits in the port slot here is what
      # gets persisted — it must still be 8080.
      view.focus_pane(:settings)
      view.select_setting(ProjectView::SETTINGS_FIELD_BASE + 4) # rows: host, port, upstream, connect, IDLE, cap
      view.set_backspace.should be_true
      view.set_input('9')
      view.settings_dirty?.should be_true
      view.settings_values[1].should eq("8080")
    ensure
      reset_projnet
    end
  end

  it "leaves the persisted GLOBAL bind_port alone, so the next project cannot inherit it" do
    reset_projnet
    Gori::Settings.project_bind_port.should be_nil # nothing pinned → the global is effective
    Runner.port_fallback(8070, 8071).should eq({8070, 8071})
    # `Settings.save` serializes `bind_port` into settings.json, and every unrelated save path
    # reaches it (pet toggle, tabs, hotkeys, env). A fallback landing here outlives the process.
    Gori::Settings.bind_port.should eq(8070)
    Gori::Settings.effective_bind_port.should eq(8070)
  ensure
    reset_projnet
  end

  it "reports no fallback when the proxy got the port it asked for" do
    Runner.port_fallback(8070, 8070).should be_nil
  end

  it "reports no fallback for an ephemeral bind, where any port IS the request" do
    # `config.port == 0` means "give me whatever is free" — being handed 41337 is the request
    # being honoured, not the environment overriding a pin.
    Runner.port_fallback(0, 41337).should be_nil
  end
end

describe "Runner.port_fallback_stands?" do
  fb = {8080, 8081}

  it "is false with no fallback recorded, so an ordinary config edit still rebinds" do
    Runner.port_fallback_stands?(nil, "127.0.0.1", 8080, "127.0.0.1", 8081).should be_false
  end

  it "holds while the config still reads the pin and the proxy is still on the fallback" do
    # An unrelated network save (upstream, http2, a listeners edit) must not drag the accept
    # socket back to a port the operator's client was told not to use.
    Runner.port_fallback_stands?(fb, "127.0.0.1", 8080, "127.0.0.1", 8081).should be_true
  end

  it "yields to a real edit: a new port is the operator moving the pin, and rebinds" do
    Runner.port_fallback_stands?(fb, "127.0.0.1", 9000, "127.0.0.1", 8081).should be_false
  end

  it "yields to a host change even when the port still matches" do
    Runner.port_fallback_stands?(fb, "0.0.0.0", 8080, "127.0.0.1", 8081).should be_false
  end

  it "is SELF-CLEARING — once a rebind moves the socket the memo can never suppress again" do
    # No explicit invalidation anywhere: the live port is part of the match, so the first
    # successful rebind (to 9000 here) makes the recorded pair permanently unmatchable, and a
    # later return to 8080 is treated as the deliberate edit it is.
    Runner.port_fallback_stands?(fb, "127.0.0.1", 8080, "127.0.0.1", 9000).should be_false
  end
end
