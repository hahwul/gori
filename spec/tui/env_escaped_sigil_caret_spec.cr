require "../spec_helper"
require "../support/memory_backend"

# `$$` in the buffer, as the CARET scanner reads it (`TextArea#env_caret_token`) — the one
# question the peek and the dropdown both ask, and the one they used to get wrong.
#
# Both stages of that scanner find their sigil by looking one character back, and `$` can precede
# itself: for `Host: $$ENV.HOST` the SECOND sigil satisfied the test, so the tooltip printed the
# value and the popup opened over a span the wire ships literally. Every example here pins the
# editor's answer to `Env.regions`/`Env.expand` — the painter and the send path — because the
# defect was not "the scanner is wrong about the grammar" but "the scanner disagrees with the two
# things that actually decide the bytes".
private def with_env_fixture(&)
  saved_vars = Gori::Settings.env_vars
  saved_project = Gori::Settings.project_env_vars
  saved_prefix = Gori::Settings.env_prefix
  Gori::Settings.env_vars = [{"HOST", "api.test"}]
  Gori::Settings.project_env_vars = [] of {String, String}
  Gori::Settings.env_prefix = "$"
  begin
    yield
  ensure
    Gori::Settings.env_vars = saved_vars
    Gori::Settings.project_env_vars = saved_project
    Gori::Settings.env_prefix = saved_prefix
  end
end

# The tooltip row, as painted, with the caret parked `cx` columns into `text` in read mode.
private def peek_row(text : String, cx : Int32) : String
  ta = Gori::Tui::TextArea.new(text)
  ta.env_complete = true
  ta.move(0, cx)
  b = MemoryBackend.new(70, 8)
  ta.render(Gori::Tui::Screen.new(b), Gori::Tui::Rect.new(0, 0, 70, 8),
    cursor: false, highlight: :request, peek: true)
  b.row(1).strip
end

# Typed one character at a time, so the popup is refreshed exactly as an operator's keystrokes
# refresh it (`insert` → `refresh_env_complete`).
private def typed(text : String) : Gori::Tui::TextArea
  ta = Gori::Tui::TextArea.new
  ta.env_complete = true
  text.each_char { |c| ta.insert(c) }
  ta
end

describe "TextArea env caret scanner on an escaped sigil" do
  it "reads no token in a namespaced `$$ENV.HOST` — the peek and the dropdown follow the wire" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        # The painter and the send path first: this span carries NO reference, and ships as text.
        Gori::Env.regions("Host: $$ENV.HOST").should be_empty
        Gori::Env.expand("Host: $$ENV.HOST").should eq("Host: $ENV.HOST")
        # Caret in the NAME half (stage B) and in the NAMESPACE run (stage A) — both used to
        # answer, one with the value and one with the namespace row.
        peek_row("Host: $$ENV.HOST", 14).should be_empty
        peek_row("Host: $$ENV.HOST", 16).should be_empty
        peek_row("Host: $$ENV.HOST", 10).should be_empty
      end
    end
  end

  it "opens no dropdown behind an escaped sigil, in either grammar" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        # `$$EN` used to offer the `$ENV.` opener, so ↹ wrote a reference into bytes that would
        # ship the escape literally — the dropdown was the half that put it there.
        typed("Host: $$EN").env_completing?.should be_false
        typed("Host: $$ENV.HO").env_completing?.should be_false
        typed("Host: $$").env_completing?.should be_false
      end
      with_env_syntax(Gori::Env::Syntax::Bare) do
        typed("Host: $$HO").env_completing?.should be_false
      end
    end
  end

  it "reads no token in a bare `$$HOST` either — the hole this grammar always had" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Bare) do
        Gori::Env.regions("Host: $$HOST").should be_empty
        Gori::Env.expand("Host: $$HOST").should eq("Host: $$HOST")
        peek_row("Host: $$HOST", 12).should be_empty
        peek_row("Host: $$HOST", 9).should be_empty
        typed("Host: $$HOST").env_completing?.should be_false
      end
    end
  end

  it "still reads nothing in a namespaced `$$$ENV.HOST`, where the escape eats the third sigil" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        # Not an "escaped sigil plus a real token": the namespaced escape is the WHOLE
        # `$$ENV.NAME`, so the run's last sigil swallows the namespace and the wire gets
        # `$$ENV.HOST`. A peek here would name a value nothing resolves.
        Gori::Env.regions("$$$ENV.HOST").should be_empty
        Gori::Env.expand("$$$ENV.HOST").should eq("$$ENV.HOST")
        peek_row("$$$ENV.HOST", 11).should be_empty
        typed("$$$ENV.HOST").env_completing?.should be_false
      end
    end
  end

  it "keeps the peek and the dropdown on a bare `$$$HOST`, which really does expand" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Bare) do
        # The bare escape is the PAIR, consumed with nothing behind it read — so an EVEN run of
        # sigils leaves a live token, and the painter paints one. Rejecting on "the previous
        # character is a sigil" alone would have made the editor mute over a token that resolves.
        Gori::Env.regions("$$$HOST").size.should eq(1)
        Gori::Env.expand("$$$HOST").should eq("$$api.test")
        peek_row("$$$HOST", 7).should contain("api.test")
        typed("$$$HO").env_completing?.should be_true
      end
    end
  end

  it "is unchanged for a lone sigil in either grammar" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        peek_row("Host: $ENV.HOST", 15).should contain("api.test")
        typed("Host: $ENV.HO").env_completing?.should be_true
      end
      with_env_syntax(Gori::Env::Syntax::Bare) do
        peek_row("Host: $HOST", 11).should contain("api.test")
        typed("Host: $HO").env_completing?.should be_true
      end
    end
  end
end
