require "../spec_helper"
require "../support/memory_backend"

# The caret value PEEK under the namespaced grammar. It shares `env_caret_token` with the
# dropdown — there used to be two walks and they would have disagreed the moment `.` became
# structure — so what is asserted here is the half only the peek decides: WHICH table answers,
# whether the value is masked, and the spelled label.

private def with_env_fixture(&)
  saved_vars = Gori::Settings.env_vars
  saved_project = Gori::Settings.project_env_vars
  saved_prefix = Gori::Settings.env_prefix
  Gori::Settings.env_vars = [{"HOST", "api.test"}, {"TOKEN", "s3cr3t-value"}]
  Gori::Settings.project_env_vars = [] of {String, String}
  Gori::Settings.env_prefix = "$"
  previous_layer = Gori::Env.layer
  begin
    with_store do |store|
      b = Gori::Bindings.load(store)
      # `TOKEN` deliberately exists in BOTH namespaces with DIFFERENT values: that collision is
      # the whole reason the namespaces exist, and a peek that reads the wrong table here is
      # the surface where an operator would never notice.
      b.add("TOKEN", "", Gori::ExtractKind::JsonPath, "$.t").should be_nil
      head = "HTTP/1.1 200 OK\r\n\r\n"
      b.observe(
        Gori::Repeater::Result.new(head.to_slice, %({"t":"BOUNDWIREVALUE"}).to_slice,
          Gori::Proxy::Codec::Http1.parse_response_head(head.to_slice), 1_i64, nil),
        Gori::InterceptFilter::Subject.new(method: "POST", host: "acme.test", target: "/login",
          scheme: "https", status: 200)).should eq(["TOKEN"])
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

# The tooltip row, as painted, with the caret parked `cx` columns into `text` in read mode.
private def peek_row(text : String, cx : Int32, literal : Set(String)? = nil) : String
  ta = Gori::Tui::TextArea.new(text)
  ta.env_complete = true
  ta.env_literal_names = literal if literal
  ta.move(0, cx)
  b = MemoryBackend.new(70, 8)
  ta.render(Gori::Tui::Screen.new(b), Gori::Tui::Rect.new(0, 0, 70, 8),
    cursor: false, highlight: :request, peek: true)
  b.row(1).strip
end

describe "TextArea env peek (namespaced)" do
  it "resolves from the namespace IN THE BYTES, not from a merged table" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        # `TOKEN` is in both tables with different values; the spelling decides.
        peek_row("k=$ENV.TOKEN", 9).should contain("s3cr3t-value")
        peek_row("k=$ENV.TOKEN", 9).should contain("$ENV.TOKEN")
      end
    end
  end

  it "masks a BIND value and never prints it in full" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        row = peek_row("k=$BIND.TOKEN", 10)
        row.should contain("$BIND.TOKEN")
        # Masked per NAMESPACE: a BIND value came off the wire, whatever its rule's state.
        row.should_not contain("BOUNDWIREVALUE")
        row.should_not be_empty
      end
    end
  end

  it "says nothing while the caret is still in the namespace run" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        # `$EN|V.TOKEN` is not on a reference yet, and answering from one table or the other
        # there would be guessing at which of two secrets the operator is pointing at.
        peek_row("k=$ENV.TOKEN", 4).should be_empty
      end
    end
  end

  it "says nothing for a bare spelling, which this grammar does not resolve" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        # `$TOKEN` ships as six literal bytes under this grammar. A peek showing the env var's
        # value would promise a substitution the send path will not make — exactly the lie the
        # evidence-tab guard exists to prevent, arriving here through the grammar instead.
        peek_row("k=$TOKEN", 5).should be_empty
        peek_row("k=$ENV.NOPE", 9).should be_empty # unregistered: just text
      end
    end
  end

  it "withholds a peek for a name this buffer ships literally, keyed QUALIFIED" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        # An evidence buffer's literal set carries both spellings (`Env.literal_keys`), and the
        # qualified one is what the peek asks about — so a literal `BIND.TOKEN` cannot silence
        # the peek on `$ENV.TOKEN`.
        peek_row("k=$ENV.TOKEN", 9, Set{"ENV.TOKEN", "TOKEN"}).should be_empty
        peek_row("k=$ENV.TOKEN", 9, Set{"BIND.TOKEN"}).should contain("s3cr3t-value")
      end
    end
  end
end
