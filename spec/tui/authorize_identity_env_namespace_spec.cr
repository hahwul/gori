require "../spec_helper"
require "../support/memory_backend"
require "../../src/gori/tui/authorize_identity_overlay"

include Gori::Tui

private alias Identity = Gori::Authorize::Identity

# The ONE editor whose bytes run the BIND pass and nothing else: an Authorize identity's SET
# headers are resolved by `Env.expand_bindings_as` on the replay path, and no `Env.expand` ever
# walks them — in either grammar. So a `$ENV.UA` accepted from this dropdown would ship as seven
# literal characters on every identity of every run, with nothing said about it, and the value
# peek under the caret would have named the value it was not sending.
#
# ENV = {HOST, UA}; BIND = {SESSION}, genuinely bound through an extract rule so `vars_for(Bind)`
# answers it.
private def with_env_fixture(&)
  saved_vars = Gori::Settings.env_vars
  saved_project = Gori::Settings.project_env_vars
  saved_prefix = Gori::Settings.env_prefix
  Gori::Settings.env_vars = [{"HOST", "api.test"}, {"UA", "gori/1.0"}]
  Gori::Settings.project_env_vars = [] of {String, String}
  Gori::Settings.env_prefix = "$"
  previous_layer = Gori::Env.layer
  begin
    with_store do |store|
      b = Gori::Bindings.load(store)
      b.add("SESSION", "", Gori::ExtractKind::JsonPath, "$.t").should be_nil
      head = "HTTP/1.1 200 OK\r\n\r\n"
      b.observe(
        Gori::Repeater::Result.new(head.to_slice, %({"t":"SESSIONCOOKIEVALUE"}).to_slice,
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

private def okey(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

# The form with the caret in the SET-headers buffer, `text` typed into it one key at a time.
private def identity_form(text : String) : AuthorizeIdentityOverlay
  ov = AuthorizeIdentityOverlay.new(Identity.new("admin"))
  ov.set_selected(AuthorizeIdentityOverlay::EDITOR_ROW)
  text.each_char { |c| ov.handle_key(okey(Termisu::Input::Key::LowerA, c)) }
  ov
end

# The whole card as painted — the dropdown and the value peek are drawn INTO it, so this is what
# the operator is being offered.
private def painted(ov : AuthorizeIdentityOverlay, w = 100, h = 30) : String
  b = MemoryBackend.new(w, h)
  ov.render(Screen.new(b), Rect.new(0, 0, w, h))
  (0...h).map { |y| b.row(y) }.join('\n')
end

describe "AuthorizeIdentityOverlay env completion" do
  it "offers the BIND namespace only" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        screen = painted(identity_form("Cookie: $"))
        screen.should contain("$BIND.")
        screen.should contain("session bindings")
        # No opener and no flattened row for a namespace this path never resolves.
        screen.should_not contain("$ENV.")
        screen.should_not contain("build-time env vars")
        screen.should_not contain("gori/1.0")
        screen.should_not contain("api.test")
      end
    end
  end

  it "offers nothing for a partial only ENV could answer" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        ov = identity_form("Cookie: $U")
        painted(ov).should_not contain("UA")
        # …and the popup is really CLOSED, not merely empty on screen: ↹ reaches the form's row
        # navigation instead of being claimed by a list (`handle_key` routes the popup first).
        ov.handle_key(okey(Termisu::Input::Key::Tab))
        ov.selected.should eq(AuthorizeIdentityOverlay::SAVE_ROW)
        ov.set_headers.should eq([{"Cookie", "$U"}])
      end
    end
  end

  it "still offers the BIND names for an already typed `$BIND.`" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        ov = identity_form("Cookie: $BIND.")
        painted(ov).should contain("$BIND.SESSION")
        # ↹ is claimed by the open list and completes the reference — the affordance this
        # editor exists for is untouched.
        ov.handle_key(okey(Termisu::Input::Key::Tab))
        ov.selected.should eq(AuthorizeIdentityOverlay::EDITOR_ROW)
        ov.set_headers.should eq([{"Cookie", "$BIND.SESSION"}])
      end
    end
  end

  it "never peeks a value for an ENV token pasted into the buffer" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        # The caret sits at the end of a COMPLETE, registered `$ENV.UA` — the shape that
        # tooltips its value everywhere the env pass actually runs.
        painted(identity_form("Cookie: $ENV.UA")).should_not contain("gori/1.0")
        # The pass this path DOES run still answers, masked as a binding always is.
        peeked = painted(identity_form("Cookie: $BIND.SESSION"))
        peeked.should contain("$BIND.SESSION")
        peeked.should_not contain("SESSIONCOOKIEVALUE")
      end
    end
  end

  # The guard against a vacuous spec above: the SAME keystrokes in an editor whose send path runs
  # both passes still offer ENV, so what is asserted there is the narrowing and not a broken
  # completer.
  it "leaves an editor that resolves both namespaces alone" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        ta = TextArea.new
        ta.env_complete = true
        "Cookie: $".each_char { |c| ta.insert(c) }
        b = MemoryBackend.new(70, 12)
        ta.render(Screen.new(b), Rect.new(0, 0, 70, 12), cursor: true)
        rows = (1...12).map { |y| b.row(y) }.join('\n')
        rows.should contain("$ENV.")
        rows.should contain("$BIND.")
      end
    end
  end
end
