require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# The Fuzzer's Project payload set (#1352): a QL-selected slice of the project's own captured data,
# projected into values. What these pin on the TUI: the set is a structured thing that survives a
# session round-trip and reads as itself in a row, its size is NEVER computed on the render fiber,
# and the run reads the project through the shared plan builder — with the secret policy, the
# refusals and the report the other surfaces have.
private CLOCK = [1_700_000_000_000_000_i64]

private def seed(store : Gori::Store, target : String, host = "api.test", resp_body = "ok") : Nil
  CLOCK[0] += 1000
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: CLOCK[0], scheme: "https", host: host, port: 443, method: "GET", target: target,
    http_version: "HTTP/1.1", head: "GET #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice,
    body: nil, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice, body: resp_body.to_slice))
end

private def project_view(*sets : SetSpec) : FuzzerView
  view = FuzzerView.new
  view.load_request("https://t.test", "GET /find?term=§x§ HTTP/1.1\r\nHost: t.test\r\n\r\n", false, "")
  sets.each { |s| view.apply_set(nil, s) }
  view
end

private def okey(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

private def otype(ov : FuzzSetOverlay, s : String) : Nil
  s.each_char { |c| ov.handle_key(okey(Termisu::Input::Key::LowerA, c)) }
end

describe "Fuzzer Project payload set" do
  describe Gori::Tui::SetSpec do
    it "round-trips its source through the stored value" do
      spec = SetSpec.project("host:api.test method:POST", Gori::PayloadFrom::Projection::ParamValues, true)
      spec.kind.should eq(:project)
      ps = spec.project_spec.not_nil!
      ps.query.should eq("host:api.test method:POST")
      ps.projection.should eq(Gori::PayloadFrom::Projection::ParamValues)
      ps.include_sensitive.should be_true
      SetSpec.project("", Gori::PayloadFrom::Projection::ParamNames, false).project_spec.not_nil!.include_sensitive.should be_false
    end

    it "reads as one line naming the source, and marks the opt-in" do
      SetSpec.project("host:api.test", Gori::PayloadFrom::Projection::ParamNames, false).display.should eq("host:api.test param-names")
      SetSpec.project("", Gori::PayloadFrom::Projection::PathSegments, false).display.should eq("path-segments")
      SetSpec.project("host:x", Gori::PayloadFrom::Projection::Extracted, true).display.should eq("host:x extracted · SENSITIVE")
    end

    it "reads an unparseable stored value as unreadable, never raising" do
      SetSpec.new(:project, "not json").project_spec.should be_nil
      SetSpec.new(:project, "not json").display.should eq("(unreadable project source)")
      SetSpec.new(:project, %({"projection":"bogus"})).project_spec.should be_nil
      SetSpec.new(:list, "a\n").project_spec.should be_nil
    end
  end

  describe Gori::Tui::FuzzSetOverlay do
    it "builds a project set from the query, the projection selector and the opt-in, safe by default" do
      ov = FuzzSetOverlay.for_list
      6.times { ov.handle_key(okey(Termisu::Input::Key::Right)) } # List → … → Project
      spec = ov.build_spec.not_nil!
      spec.kind.should eq(:project)
      ps = spec.project_spec.not_nil!
      ps.projection.should eq(Gori::PayloadFrom::Projection::ParamNames)
      ps.include_sensitive.should be_false # the opt-in starts OFF
      ps.query.should eq("")

      ov.handle_key(okey(Termisu::Input::Key::Down)) # Type row → the query field
      otype(ov, "host:api.test")
      ov.handle_key(okey(Termisu::Input::Key::Down)) # → projection selector
      2.times { ov.handle_key(okey(Termisu::Input::Key::Right)) }
      ov.handle_key(okey(Termisu::Input::Key::Down)) # → the sensitive row
      ov.handle_key(okey(Termisu::Input::Key::Space, ' '))
      built = ov.build_spec.not_nil!.project_spec.not_nil!
      built.query.should eq("host:api.test")
      built.projection.should eq(Gori::PayloadFrom::Projection::PathSegments)
      built.include_sensitive.should be_true
    end

    it "wraps the projection selector both ways and applies from the last row" do
      ov = FuzzSetOverlay.for_list
      6.times { ov.handle_key(okey(Termisu::Input::Key::Right)) }
      2.times { ov.handle_key(okey(Termisu::Input::Key::Down)) } # → the projection selector
      ov.handle_key(okey(Termisu::Input::Key::Left))
      ov.build_spec.not_nil!.project_spec.not_nil!.projection.should eq(Gori::PayloadFrom::Projection::Extracted)
      ov.handle_key(okey(Termisu::Input::Key::Right))
      ov.build_spec.not_nil!.project_spec.not_nil!.projection.should eq(Gori::PayloadFrom::Projection::ParamNames)
      ov.handle_key(okey(Termisu::Input::Key::Enter)).should eq(:stay) # not the last row: moves on
      ov.handle_key(okey(Termisu::Input::Key::Enter)).should eq(:commit)
    end

    it "seeds an existing project set back into its fields" do
      spec = SetSpec.project("path:/api", Gori::PayloadFrom::Projection::JsEndpoints, true)
      ov = FuzzSetOverlay.editing(spec, 0)
      ov.build_spec.not_nil!.value.should eq(spec.value)
    end

    it "draws the Type row with Project in it, the QL, the selector, and the opt-in loudly when it is on" do
      ov = FuzzSetOverlay.editing(SetSpec.project("host:api.test", Gori::PayloadFrom::Projection::ParamValues, true), 0)
      backend = MemoryBackend.new(120, 30)
      ov.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
      ["Project", "Query", "Reads", "Secrets", "host:api.test", "‹ param-values ›", "decoded once", "ON"].each do |w|
        backend.contains?(w).should be_true
      end
      # and at the narrowest common terminal the seventh type label still fits
      narrow = MemoryBackend.new(80, 24)
      ov.render(Screen.new(narrow), Rect.new(0, 0, 80, 24))
      narrow.contains?("Project").should be_true
    end

    it "shows every projection when cycled, and names what each reads (none is cut off the card)" do
      ov = FuzzSetOverlay.editing(SetSpec.project("", Gori::PayloadFrom::Projection::ParamNames, false), 0)
      2.times { ov.handle_key(okey(Termisu::Input::Key::Down)) } # → the projection selector
      seen = [] of String
      5.times do
        backend = MemoryBackend.new(80, 24)
        ov.render(Screen.new(backend), Rect.new(0, 0, 80, 24))
        seen << (0...24).map { |y| backend.row(y) }.join("\n")
        ov.handle_key(okey(Termisu::Input::Key::Right))
      end
      ["‹ param-names ›", "‹ param-values ›", "‹ path-segments ›", "‹ js-endpoints ›", "‹ extracted ›"].each_with_index do |chip, i|
        seen[i].should contain(chip)
      end
      seen.last.should contain("needs Secrets")
    end

    it "is off by default in the safe direction: a fresh Project row says credential material stays out" do
      ov = FuzzSetOverlay.for_list
      6.times { ov.handle_key(okey(Termisu::Input::Key::Right)) }
      backend = MemoryBackend.new(120, 30)
      ov.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
      backend.contains?("credential material stays out").should be_true
    end
  end

  describe Gori::Tui::FuzzerView do
    it "persists a project set across a session round-trip" do
      spec = SetSpec.project("host:api.test", Gori::PayloadFrom::Projection::ParamNames, false)
      src = project_view(spec)
      dst = FuzzerView.new
      dst.load_request("https://t.test", "GET /find?term=§x§ HTTP/1.1\r\nHost: t.test\r\n\r\n", false, "")
      dst.duplicate_from(src) # config_json → apply_config_json
      dst.set_specs.size.should eq(1)
      dst.set_specs.first.kind.should eq(:project)
      dst.set_specs.first.value.should eq(spec.value)
    end

    it "never reads the project to estimate a run's size on the render fiber" do
      view = project_view(SetSpec.project("", Gori::PayloadFrom::Projection::ParamNames, false))
      view.run_request_count.should be_nil # unknown until the plan builder resolves it
    end

    it "reads the project through the plan builder: values, a report, and the plan's own total" do
      with_store do |store|
        seed(store, "/a?alphaparam=1&betaparam=2")
        view = project_view(SetSpec.project("host:api.test", Gori::PayloadFrom::Projection::ParamNames, false))
        engine, err = view.build_engine(false, Gori::Scope.load(store), nil, store)
        err.should be_nil
        engine.not_nil!.total.should eq(2_i64)
        rep = view.payload_reports.first
        rep.values.should eq(2)
        rep.source.should eq("host:api.test param-names")
        rep.policy.should eq("sensitive-excluded")
      end
    end

    it "names a refusal in place of the run: no project, an empty source, withheld credentials" do
      with_store do |store|
        seed(store, "/a?password=hunter2")
        scope = Gori::Scope.load(store)
        view = project_view(SetSpec.project("", Gori::PayloadFrom::Projection::ParamNames, false))
        _e, err = view.build_engine(false, scope, nil, nil)
        err.to_s.should contain("no project to read")
        view.payload_reports.should be_empty
        nothing = project_view(SetSpec.project("host:nowhere.test", Gori::PayloadFrom::Projection::ParamNames, false))
        _e, err = nothing.build_engine(false, scope, nil, store)
        err.to_s.should contain("produced no values")
        held = project_view(SetSpec.project("", Gori::PayloadFrom::Projection::ParamValues, false))
        _e, err = held.build_engine(false, scope, nil, store)
        err.to_s.should contain("sensitive skipped")
        err.to_s.should_not contain("hunter2")
      end
    end

    it "refuses the extracted projection without the opt-in, with the reason" do
      with_store do |store|
        seed(store, "/a?x=1")
        view = project_view(SetSpec.project("", Gori::PayloadFrom::Projection::Extracted, false))
        _e, err = view.build_engine(false, Gori::Scope.load(store), nil, store)
        err.to_s.should contain("refused unless you say you want them")
      end
    end

    it "does not drain the search index on the event loop: a body: source says the index is behind" do
      with_store do |store|
        store.pause_background_index
        seed(store, "/a?alphaparam=1", resp_body: "the needle is here")
        view = project_view(SetSpec.project("body:needle", Gori::PayloadFrom::Projection::ParamNames, false))
        _e, err = view.build_engine(false, Gori::Scope.load(store), nil, store)
        # nothing was indexed, and the TUI did not wait for a writer to index it: the refusal says why
        err.to_s.should contain("produced no values")
        err.to_s.should contain("search index is 1 flow behind")
      end
    end

    it "reads a fresh project on the next run" do
      with_store do |store|
        seed(store, "/a?alphaparam=1")
        view = project_view(SetSpec.project("", Gori::PayloadFrom::Projection::ParamNames, false))
        scope = Gori::Scope.load(store)
        view.build_engine(false, scope, nil, store)[0].not_nil!.total.should eq(1_i64)
        seed(store, "/b?betaparam=1")
        view.build_engine(false, scope, nil, store)[0].not_nil!.total.should eq(2_i64)
      end
    end
  end
end
