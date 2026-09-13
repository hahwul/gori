require "../spec_helper"

# `Highlight.with_env_tokens` under the namespaced grammar.
#
# The painter is the affordance the CLI and MCP have to state in a refusal: an operator sees
# before sending whether a token will resolve. So the SPAN has to be the whole reference (the
# predecessor sliced the name with a `prefix.size` offset, which under this grammar cut
# `ENV.HOST` and matched nothing in the literal set) and `known` has to be answered by the
# namespace's OWN table.

private def with_env_fixture(&)
  saved_vars = Gori::Settings.env_vars
  saved_project = Gori::Settings.project_env_vars
  saved_prefix = Gori::Settings.env_prefix
  Gori::Settings.env_vars = [{"HOST", "api.test"}]
  Gori::Settings.project_env_vars = [] of {String, String}
  Gori::Settings.env_prefix = "$"
  previous_layer = Gori::Env.layer
  begin
    with_store do |store|
      b = Gori::Bindings.load(store)
      b.add("SESSION", "", Gori::ExtractKind::JsonPath, "$.t").should be_nil
      b.add("PENDING", "", Gori::ExtractKind::JsonPath, "$.p").should be_nil
      head = "HTTP/1.1 200 OK\r\n\r\n"
      b.observe(
        Gori::Repeater::Result.new(head.to_slice, %({"t":"COOKIEVAL"}).to_slice,
          Gori::Proxy::Codec::Http1.parse_response_head(head.to_slice), 1_i64, nil),
        Gori::InterceptFilter::Subject.new(method: "POST", host: "acme.test", target: "/login",
          scheme: "https", status: 200)).should eq(["SESSION"])
      Gori::Env.layer = b
      yield
    end
  ensure
    Gori::Env.layer = previous_layer
    Gori::Settings.env_vars = saved_vars
    Gori::Settings.project_env_vars = saved_project
    Gori::Settings.env_prefix = saved_prefix
  end
end

# {painted text, known?} for every token span in `raw`.
private def token_spans(raw : String, literal : Set(String)? = nil) : Array({String, Bool})
  line = Gori::Tui::Highlight.with_env_tokens(
    [Gori::Tui::Highlight::Span.new(raw, Gori::Tui::Theme.text)], literal)
  line.compact_map do |span|
    if span.fg == Gori::Tui::Theme.env_known
      {span.text, true}
    elsif span.fg == Gori::Tui::Theme.env_unknown
      {span.text, false}
    end
  end
end

describe "Highlight.with_env_tokens (namespaced)" do
  it "paints the WHOLE reference, namespace included" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        token_spans("Host: $ENV.HOST/x").should eq([{"$ENV.HOST", true}])
      end
    end
  end

  it "paints an unregistered name as unknown, and a bare spelling as no token at all" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        token_spans("a=$ENV.NOPE").should eq([{"$ENV.NOPE", false}])
        # `$HOST` resolves nothing under this grammar — painting it as a known token would
        # promise a substitution the send path will not make.
        token_spans("a=$HOST").should be_empty
      end
    end
  end

  it "answers BIND from the binding table: bound is known, declared-but-unbound is not" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        # One line, two namespaces, two tables — the thing a single merged `vars` argument
        # cannot express, and the operator's pre-send answer to "did my login actually bind it".
        token_spans("$ENV.HOST/$BIND.SESSION/$BIND.PENDING").should eq([
          {"$ENV.HOST", true}, {"$BIND.SESSION", true}, {"$BIND.PENDING", false},
        ])
      end
    end
  end

  it "dims a literal name by its QUALIFIED key, with no bleed between namespaces" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        # An evidence buffer ships these bytes as they arrived, so what resolves globally is not
        # what THIS buffer will send.
        token_spans("$ENV.HOST", Set{"ENV.HOST"}).should eq([{"$ENV.HOST", false}])
        # …and a literal in the OTHER namespace must not touch it. The predecessor keyed on the
        # bare name alone, so one `id` withheld both.
        token_spans("$ENV.HOST", Set{"BIND.HOST"}).should eq([{"$ENV.HOST", true}])
      end
    end
  end

  it "finds no token where there is no namespace" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        token_spans("$ENV./x").should be_empty # an empty name is not a name
        token_spans("GET /a.b HTTP").should be_empty
        token_spans("$env.HOST").should be_empty  # case-SENSITIVE, deliberately
        token_spans("$$ENV.HOST").should be_empty # an escape is the literal, not a reference
      end
    end
  end
end
