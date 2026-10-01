require "../spec_helper"

include Gori::Tui

# A held message is EVIDENCE (#1416). Its bytes were sent by a client (or an origin), and an
# edit to one header does not make the rest of them the operator's: the intercept editor used to
# run the `$ENV`/`$GEN` pass over the whole buffer, so appending one byte to the request line put
# a project secret into a captured `a=$ENV.FOO`, minted a value for a captured `$GEN.UUID`,
# consumed every `$$`, and resynced Content-Length to match. Names the held message arrived with
# now stay literal; a name the operator types is still a reference.
#
# Every example names its grammar. The spec default is BARE, where `$ENV.FOO` is the token `ENV`
# followed by `.FOO` — an example written in namespaced spelling under it passes with or without
# the fix.

private def iet_interceptor(&)
  with_store do |store|
    ic = Gori::Interceptor.new(Gori::Scope.load(store))
    ic.toggle # enable
    yield ic
  end
end

# Project vars for one example, with the process-global env state it touches put back as it was.
private def with_vars(vars : Array({String, String}), &)
  prev_global = Gori::Settings.env_vars
  prev_project = Gori::Settings.project_env_vars
  prev_prefix = Gori::Settings.env_prefix
  Gori::Settings.env_prefix = "$"
  Gori::Settings.env_vars = [] of {String, String}
  Gori::Settings.project_env_vars = vars
  begin
    yield
  ensure
    Gori::Settings.env_vars = prev_global
    Gori::Settings.project_env_vars = prev_project
    Gori::Settings.env_prefix = prev_prefix
    Gori::Env.bump_highlight_rev
  end
end

# Hold `raw` as a request and open the editor on it.
private def held_request(ic : Gori::Interceptor, raw : String) : InterceptView
  spawn do
    ic.hold_request(raw.to_slice, method: "POST", target: "/held",
      host: "127.0.0.1", port: 19501, scheme: "http")
  end
  Fiber.yield
  view = InterceptView.new
  view.reload(ic)
  view.toggle_edit
  view
end

# Dirty the buffer without touching anything a token sits in: one byte on the request line.
private def touch_request_line(view : InterceptView) : Nil
  view.edit_end
  view.edit_insert('x')
end

private def forwarded(view : InterceptView) : String
  String.new(view.forward_bytes(view.selected_item.not_nil!))
end

private def namespaced(&)
  with_env_syntax(Gori::Env::Syntax::Namespaced) { yield }
end

describe "InterceptView: a held message's own $ tokens (#1416)" do
  it "forwards a captured $ENV / $GEN body byte-exact after a request-line edit" do
    namespaced do
      with_vars([{"FOO", "secretvalue"}]) do
        iet_interceptor do |ic|
          body = "a=$ENV.FOO&b=$GEN.UUID"
          view = held_request(ic, "POST /held HTTP/1.1\r\nHost: h\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
          touch_request_line(view)

          out = forwarded(view)
          out.should eq("POST /held HTTP/1.1x\r\nHost: h\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
          out.should_not contain("secretvalue")
          # The pane never showed an enlarged Content-Length either: it reads the same bytes.
          view.editor_text.should contain("Content-Length: #{body.bytesize}\r\n")
        end
      end
    end
  end

  # The issue's `pa$$word` came out shorter under THIS grammar. An escape never enters the
  # literal set, so `$$FOO` / `$$word` staying whole also pins that the bare `$$` is read as one
  # two-byte literal — re-reading its second sigil would resolve `$FOO` / `$word`.
  it "keeps the bare-grammar twin literal too, escapes included" do
    with_env_syntax(Gori::Env::Syntax::Bare) do
      with_vars([{"FOO", "secretvalue"}, {"word", "W"}]) do
        iet_interceptor do |ic|
          body = "a=$FOO&b=$$FOO&pa$$word"
          view = held_request(ic, "POST /held HTTP/1.1\r\nHost: h\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
          touch_request_line(view)
          forwarded(view).should end_with("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
        end
      end
    end
  end

  it "leaves a captured $$ escape as the two bytes the client sent" do
    namespaced do
      with_vars([{"FOO", "secretvalue"}]) do
        iet_interceptor do |ic|
          body = "pa$$word&b=$$ENV.FOO"
          view = held_request(ic, "POST /held HTTP/1.1\r\nHost: h\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
          touch_request_line(view)
          forwarded(view).should end_with("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
        end
      end
    end
  end

  # Head-only expansion would have missed this one: a client can send a token in a header.
  it "keeps a captured token in the HEAD literal" do
    namespaced do
      with_vars([{"FOO", "secretvalue"}]) do
        iet_interceptor do |ic|
          view = held_request(ic, "GET /held?q=$ENV.FOO HTTP/1.1\r\nHost: h\r\nX-Tok: $ENV.FOO\r\n\r\n")
          view.edit_move(1, 0) # the Host line
          view.edit_end
          view.edit_insert('x')
          forwarded(view).should eq("GET /held?q=$ENV.FOO HTTP/1.1\r\nHost: hx\r\nX-Tok: $ENV.FOO\r\n\r\n")
        end
      end
    end
  end

  # The #524 feature stays: a reference the operator TYPES is resolved, and a generator they
  # type mints a value, with the pane's Content-Length measuring it.
  it "expands a name the operator typed that the capture never mentioned" do
    namespaced do
      with_vars([{"FOO", "secretvalue"}, {"BAR", "typed"}]) do
        iet_interceptor do |ic|
          body = "a=$ENV.FOO"
          view = held_request(ic, "POST /held HTTP/1.1\r\nHost: h\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
          view.edit_move(1, 0)
          view.edit_end
          view.edit_newline
          "X-Bar: $ENV.BAR".each_char { |c| view.edit_insert(c) }

          out = forwarded(view)
          out.should contain("\r\nX-Bar: typed\r\n")
          out.should end_with("\r\n\r\n#{body}") # …and the captured one beside it is untouched
        end
      end
    end
  end

  # Conservative where the two collide: gori cannot tell a typed `$ENV.FOO` from the captured one,
  # and evidence wins when it cannot — the same rule the Repeater's evidence tabs follow.
  it "keeps a typed name literal when the capture already carried it" do
    namespaced do
      with_vars([{"FOO", "secretvalue"}]) do
        iet_interceptor do |ic|
          view = held_request(ic, "GET /held?q=$ENV.FOO HTTP/1.1\r\nHost: h\r\n\r\n")
          view.edit_move(1, 0)
          view.edit_end
          view.edit_newline
          "X-Foo: $ENV.FOO".each_char { |c| view.edit_insert(c) }
          out = forwarded(view)
          out.should contain("\r\nX-Foo: $ENV.FOO\r\n")
          out.should_not contain("secretvalue")
        end
      end
    end
  end

  # The literal set reads the grammar, and the operator can flip it mid-hold. Seeded namespaced,
  # the capture's `$filter` is no token at all; flipped to bare it IS one, and it must still be
  # the client's byte rather than the project's `filter`.
  it "re-derives the capture's names when the grammar flips mid-hold" do
    with_vars([{"filter", "PWNED"}]) do
      iet_interceptor do |ic|
        view = nil.as(InterceptView?)
        namespaced do
          view = held_request(ic, "GET /odata?$filter=x HTTP/1.1\r\nHost: h\r\n\r\n")
          touch_request_line(view.not_nil!)
        end
        with_env_syntax(Gori::Env::Syntax::Bare) do
          forwarded(view.not_nil!).should start_with("GET /odata?$filter=x HTTP/1.1x\r\n")
        end
      end
    end
  end

  it "keeps a held RESPONSE's own tokens literal" do
    namespaced do
      with_vars([{"FOO", "secretvalue"}]) do
        iet_interceptor do |ic|
          body = "{\"k\":\"$ENV.FOO\"}"
          raw = "HTTP/1.1 200 OK\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
          spawn do
            ic.hold_response(raw.to_slice, flow_id: nil, method: "GET", target: "200 OK",
              host: "h", port: 80, scheme: "http")
          end
          Fiber.yield
          view = InterceptView.new
          view.reload(ic)
          view.toggle_edit
          touch_request_line(view) # the status line
          forwarded(view).should eq("HTTP/1.1 200 OKx\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
        end
      end
    end
  end
end
