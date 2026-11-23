require "../spec_helper"

private def authored_options : Gori::Fuzz::PlanOptions
  Gori::Fuzz::PlanOptions.new("GET /?q=x HTTP/1.1\nHost: h\n\n",
    target: "http://h", marks: ["x"],
    sources: [Gori::Fuzz::InlineList.new(["a", "b"])].map(&.as(Gori::Fuzz::PayloadSource)))
end

describe Gori::Fuzz::PreparedSession do
  it "saves authored template and marking instructions rather than expanded or normalized bytes" do
    with_store_env do |store|
      Gori::Env.set_project_var(store, "PREP1910", "expanded")
      Gori::Settings.project_env_vars = [{"PREP1910", "expanded"}]
      options = authored_options
      options.template = "GET /$ENV.PREP1910?q=x HTTP/1.1\nHost: h\n\n"
      prepared = Gori::Fuzz::PreparedSession.build(options, ungated_outbound)
      prepared.template.should eq(options.template)
      id = prepared.insert(store, "authored", nil)
      row = store.get_fuzz_session(id).not_nil!
      view = Gori::Tui::FuzzerView.new
      view.restore(row)
      view.template_text.should eq(prepared.template)
      engine, error = view.build_engine(false, Gori::Scope.load(store), project: store)
      error.should be_nil
      engine.not_nil!.total.should eq(2_i64)
    end
  end

  it "round-trips binary, newline, blank and whitespace payloads through the view and editor" do
    values = ["", " a ", "a\nb", String.new(Bytes[0x80, 0x00]), "x,y"]
    options = authored_options
    options.sources = [Gori::Fuzz::InlineList.new(values).as(Gori::Fuzz::PayloadSource)]
    prepared = Gori::Fuzz::PreparedSession.build(options, ungated_outbound)
    state = Gori::Fuzz::SessionConfig.new
    state.apply_json(prepared.state.to_json).should be_true
    set = state.sets.first
    restored = [] of String
    set.build_source.each { |v| restored << v }
    restored.should eq(values)
    editor = Gori::Tui::FuzzSetOverlay.editing(set, 0)
    edited = editor.build_spec.not_nil!
    roundtrip = [] of String
    edited.build_source.each { |v| roundtrip << v }
    roundtrip.should eq(values)
  end

  it "keeps every supported matcher dimension after persistence" do
    options = authored_options
    matcher = options.matcher
    matcher.match_grpc = "7"
    matcher.filter_grpc = "0"
    matcher.match_lines = ">1"
    matcher.filter_lines = "0"
    matcher.match_header = "X-Test: yes"
    matcher.filter_header = "no"
    state = Gori::Fuzz::PreparedSession.build(options, ungated_outbound).state
    restored = Gori::Fuzz::SessionConfig.new
    restored.apply_json(state.to_json).should be_true
    restored.matcher.match_grpc.should eq("7")
    restored.matcher.filter_grpc.should eq("0")
    restored.matcher.match_lines.should eq(">1")
    restored.matcher.filter_lines.should eq("0")
    restored.matcher.match_header.should eq("X-Test: yes")
    restored.matcher.filter_header.should eq("no")
  end

  it "keeps generated numeric, brute and null sources lazy" do
    sources = [Gori::Fuzz::NumberRange.new(-3_i64, 3_i64, 2_i64),
               Gori::Fuzz::BruteForce.new("a:b", 1, 2), Gori::Fuzz::NullPayloads.new(3)]
    sources.each do |source|
      original = [] of String
      source.each { |v| original << v }
      restored = [] of String
      Gori::Fuzz::SetSpec.from_source(source).build_source.each { |v| restored << v }
      restored.should eq(original)
    end
  end
end

describe "Prepared Fuzzer invalid fields" do
  it "keeps malformed gRPC field JSON renderable and refuses execution" do
    with_store do |store|
      view = Gori::Tui::FuzzerView.new
      view.load_request("http://h", "GET /?q=§x§ HTTP/1.1\r\n\r\n", false, "")
      view.apply_set(nil, Gori::Tui::SetSpec.list(["p"]))
      view.apply_advanced(view.advanced_snapshot.copy_with(grpc_fields: "["))
      view.run_step.should_not be_nil
      view.run_request_count.should eq(1_i64)
      engine, error = view.build_engine(false, Gori::Scope.load(store))
      engine.should be_nil
      error.not_nil!.should contain("invalid gRPC fields JSON")
    end
  end
end

describe "Prepared wordlist paths" do
  it "keeps the resolved absolute file path when the author used a relative path" do
    file = File.tempname("gori-prepared-words")
    File.write(file, "one\ntwo\n")
    begin
      relative = Path[file].relative_to(Dir.current).to_s
      options = authored_options
      options.sources = [Gori::Fuzz::WordlistFile.new(relative).as(Gori::Fuzz::PayloadSource)]
      prepared = Gori::Fuzz::PreparedSession.build(options, ungated_outbound)
      prepared.state.sets.first.value.should eq(File.expand_path(file))
    ensure
      File.delete?(file)
    end
  end
end

describe "Prepared exec chains" do
  # Preparing validates and sends nothing, so a `¦exec:` step must not run either; the run the
  # operator starts later still renders its baseline through the chain, once.
  it "runs no command while preparing, and the run's build still does" do
    posix_only!("a #!/bin/sh hook script")
    dir = File.tempname("gori-prep-hook")
    Dir.mkdir_p(dir)
    hook = File.join(dir, "h.sh")
    tally = File.join(dir, "tally")
    File.write(hook, "#!/bin/sh\necho ran >> '#{tally}'\ncat\n")
    File.chmod(hook, 0o755)
    runs = -> { File.exists?(tally) ? File.read(tally).lines.size : 0 }
    begin
      with_store do |store|
        options = Gori::Fuzz::PlanOptions.new("GET /?q=§abc¦exec:#{hook}§ HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
          target: "http://127.0.0.1:9",
          sources: [Gori::Fuzz::InlineList.new(["a", "b"])].map(&.as(Gori::Fuzz::PayloadSource)))
        prepared = Gori::Fuzz::PreparedSession.build(options, ungated_outbound)
        prepared.insert(store, "p", nil)
        prepared.plan.total.should eq(2_i64)
        runs.call.should eq(0)
        options.run_hooks?.should be_true
        String.new(Gori::Fuzz::Plan.build(options, ungated_outbound).generator.baseline_raw).should contain("?q=abc ")
        runs.call.should eq(1)
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
