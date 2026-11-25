require "../spec_helper"

# A started Fuzzer run sweeps the config it was confirmed with. Mode and the CONFIG rows stay
# editable mid-run, and the toast and the `next run` badge say the edit waits for the next run.
# The view used to hand its live `Config` to the plan, though. `Generator#each` reads the
# Mode only once `dispatch_loop` starts, after auto-calibration. So cycling sniper to
# cluster-bomb during calibration sent the 3x3 cluster bomb under a run counted, confirmed
# and saved as a 6-request sniper.

# Answers every request with an empty 200 and records its request line.
private class SnapshotOrigin
  getter port : Int32

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.port
    @lines = [] of String
    spawn(name: "snapshot-origin") { accept_loop }
  end

  def lines : Array(String)
    @lines.dup
  end

  def close : Nil
    @server.close rescue nil
  end

  private def accept_loop : Nil
    while conn = @server.accept?
      spawn serve(conn) # the call form binds THIS conn; a block would capture the loop variable
    end
  rescue
    # listener closed at teardown
  end

  private def serve(conn : TCPSocket) : Nil
    while line = conn.gets(chomp: true)
      @lines << line
      while (h = conn.gets(chomp: true)) && !h.empty?
      end
      conn << "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
      conn.flush
    end
  rescue
    # client closed
  ensure
    conn.close rescue nil
  end
end

describe "FuzzerView — a started run keeps its start config" do
  it "sweeps the Mode it was built with after the operator cycles Mode mid-run" do
    origin = SnapshotOrigin.new
    with_store do |store|
      view = Gori::Tui::FuzzerView.new
      view.load_request("http://127.0.0.1:#{origin.port}",
        "GET /x?a=§1§&b=§2§ HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
      view.apply_set(nil, Gori::Tui::SetSpec.list(["AA", "BB", "CC"]))
      view.config.mode.sniper?.should be_true
      engine, err = view.build_engine(false, Gori::Scope.load(store), nil)
      err.should be_nil
      engine = engine.not_nil!
      confirmed = engine.total
      confirmed.should eq(6_i64)
      view.begin_run(confirmed)

      # While the run calibrates: three → on the Mode row, and a session save that folds a
      # retyped Max requests into the form's config.
      3.times { view.cycle_mode_forward }
      view.config.mode.cluster_bomb?.should be_true
      view.config.max_requests = 2_i64
      view.edited_since_run_start?.should be_true # the badge that promises "next run"

      engine.run { }
      lines = origin.lines.map { |l| l.split(' ')[1] }
      lines.size.should eq(6)
      lines.sort.should eq(%w[
        /x?a=1&b=AA /x?a=1&b=BB /x?a=1&b=CC /x?a=AA&b=2 /x?a=BB&b=2 /x?a=CC&b=2
      ])
    end
  ensure
    origin.try(&.close)
  end
end

# A peer tab's row, as the per-tick reconcile applies it (`FuzzerView#apply_peer_session`).
private def peer_row(view : Gori::Tui::FuzzerView, config : String) : Gori::Store::FuzzSessionRecord
  Gori::Store::FuzzSessionRecord.new(id: 1_i64, target: view.target, template: view.template_text,
    http2: false, sni: nil, config: config, flow_id: nil, position: 0, name: nil)
end

private def peer_config(view : Gori::Tui::FuzzerView, **edits) : String
  obj = JSON.parse(view.config_json).as_h
  edits.each { |k, v| obj[k.to_s] = JSON::Any.new(v) }
  obj.to_json
end

describe "FuzzerView — the labels a run is saved under" do
  # The plan is built before the RUN FUZZ confirm, and the reconcile keeps applying peer rows
  # under that card. `begin_run` read Mode and Max requests off the form, so the run was saved
  # as a cluster bomb capped at 2 while the engine swept the confirmed 6-request sniper.
  it "labels the run off the plan, not off a peer row applied under the confirm card" do
    with_store do |store|
      view = Gori::Tui::FuzzerView.new
      view.load_request("http://127.0.0.1:9", "GET /x?a=§1§&b=§2§ HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
      view.apply_set(nil, Gori::Tui::SetSpec.list(["AA", "BB", "CC"]))
      engine, err = view.build_engine(false, Gori::Scope.load(store), nil)
      err.should be_nil
      engine = engine.not_nil!

      view.apply_peer_session(peer_row(view, peer_config(view, mode: "ClusterBomb", max_requests: 2_i64)))
      view.config.mode.cluster_bomb?.should be_true # the setup reached the form
      view.engine = engine
      view.begin_run(engine.total)

      view.saved_run_meta(1_i64).mode.should eq("sniper")
      view.@run_max_requests.should be_nil
    end
  end

  # Calibration on (form config AND form matcher), then a peer row turns it off. The run has
  # no match rule and does not calibrate, so it judges nothing and must not count hits.
  it "is not selective when a peer turned calibration off and no rule is set" do
    with_store do |store|
      view = Gori::Tui::FuzzerView.new
      view.load_request("http://127.0.0.1:9", "GET /x?a=§1§ HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
      view.apply_set(nil, Gori::Tui::SetSpec.list(["AA"]))
      view.apply_advanced(view.advanced_snapshot.copy_with(calibrate: true))
      view.apply_peer_session(peer_row(view, peer_config(view, calibrate: false)))
      engine, err = view.build_engine(false, Gori::Scope.load(store), nil)
      err.should be_nil
      engine = engine.not_nil!
      engine.auto_calibrate?.should be_false
      view.engine = engine
      view.begin_run(engine.total)

      view.run_selective?.should be_false
      view.matcher.auto_calibrate?.should be_false # the peer sync reached the form's matcher too
    end
  end
end
