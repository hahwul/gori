require "../../spec_helper"

# `--macro` on the CLI (#1350). The flags abort on a bad value, which an example cannot observe,
# so what is pinned here is the part around them: the spec the flags build, and its defaults.
describe "gori run --macro" do
  it "asks for no macro without --macro" do
    Gori::CLI::Run.request_macro_spec("gori run fuzz", Gori::CLI::Run::RequestMacroFlags.new).should be_nil
  end

  it "defaults to a fresh value before every candidate, skipping a candidate the macro fails" do
    flags = Gori::CLI::Run::RequestMacroFlags.new
    flags.steps.concat(Gori::RequestMacro::Spec.parse_steps("csrf-fetch,7"))
    spec = Gori::CLI::Run.request_macro_spec("gori run fuzz", flags).not_nil!
    spec.steps.should eq(["csrf-fetch", "7"])
    spec.cadence.per_request?.should be_true
    spec.on_failure.should eq(Gori::RequestMacro::OnFailure::Skip)
    spec.expect.should be_empty
    spec.active?.should be_true
  end

  it "carries what the companions set, wherever they sat relative to --macro" do
    flags = Gori::CLI::Run::RequestMacroFlags.new
    flags.every = "5"
    flags.on_failure = "stop"
    flags.expect << "$CSRF"
    flags.steps << "csrf-fetch"
    spec = Gori::CLI::Run.request_macro_spec("gori run mine", flags).not_nil!
    spec.cadence.every.should eq(5)
    spec.on_failure.should eq(Gori::RequestMacro::OnFailure::Stop)
    spec.expect.should eq(["CSRF"])
  end

  it "splits a comma-separated --macro-expect the way MCP and the TUI do" do
    flags = Gori::CLI::Run::RequestMacroFlags.new
    flags.steps << "csrf-fetch"
    flags.expect << "CSRF, NONCE"
    flags.expect << "$TOKEN"
    spec = Gori::CLI::Run.request_macro_spec("gori run fuzz", flags).not_nil!
    spec.expect.should eq(["CSRF", "NONCE", "TOKEN"])
  end

  it "reads a binding name in whichever spelling the install uses" do
    spec = with_env_syntax(Gori::Env::Syntax::Namespaced) do
      Gori::RequestMacro::Spec.new(["1"], expect: ["$BIND.CSRF", "BIND.NONCE", "TOKEN"])
    end
    spec.expect.should eq(["CSRF", "NONCE", "TOKEN"])
  end

  it "keeps the steps but asks for nothing when the cadence is off" do
    flags = Gori::CLI::Run::RequestMacroFlags.new
    flags.steps << "csrf-fetch"
    flags.every = "off"
    spec = Gori::CLI::Run.request_macro_spec("gori run fuzz", flags).not_nil!
    spec.active?.should be_false
    spec.steps.should eq(["csrf-fetch"])
  end
end
