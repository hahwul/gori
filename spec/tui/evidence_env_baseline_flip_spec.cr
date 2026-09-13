require "../spec_helper"
require "../support/memory_backend"

# An EVIDENCE tab's two `$NAME` baselines across a mid-session `env.syntax` flip.
#
# Both were computed ONCE, at seed time, under whatever grammar was in force then — and the
# operator can flip the grammar from the Project tab (`s`) or the Settings env card (`s`) at any
# moment. Seeded namespaced and flipped to bare, a captured GraphQL `$id` was in neither set
# (`token_names(ns: Env)` found no namespaced token to name), so `vars_without({})` handed the
# send path the WHOLE table and the capture's own `$id` went out as a project value — the exact
# leak the evidence baseline exists to prevent, reintroduced by a keystroke two tabs away.
# Flipped the other way the literal set held the bare `ENV` while the painter asks about
# `ENV.id`, so the token painted as resolvable over bytes the wire carries verbatim.
#
# So the baselines are kept as the SEED BYTES plus the revision they were read under, and
# re-derived when the grammar moves. The bytes are the seed's, never the current buffer's: a
# token the operator types after the flip is still theirs, which every example below pins in the
# same breath as the capture's.
include Gori::Tui

private def with_env_fixture(&)
  saved_vars = Gori::Settings.env_vars
  saved_project = Gori::Settings.project_env_vars
  saved_prefix = Gori::Settings.env_prefix
  # `id` is the collision this whole change is about: an ordinary env var name that is also a
  # GraphQL variable, a Mongo field and an OData option.
  Gori::Settings.env_vars = [{"id", "SECRET-ID"}, {"HOST", "api.test"}]
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

private def graphql_request(token : String) : String
  body = %({"query":"query(#{token}: ID!){ user(id: #{token}){ name } }"})
  "POST /graphql HTTP/1.1\r\nHost: h.test\r\nContent-Type: application/json\r\n" \
  "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
end

# A tab whose bytes came off the wire (^R from History persists through exactly this seam).
private def evidence_tab(request : String) : RepeaterView
  view = RepeaterView.new
  view.restore("http://127.0.0.1", request, false, false, evidence: true)
  view
end

# The foreground the request editor paints the FIRST sigil with. `Theme.env_known` is the paint
# that promises "this resolves on send"; anything else is the editor calling it text.
private def first_sigil_fg(view : RepeaterView) : Gori::Tui::Color
  b = MemoryBackend.new(90, 24)
  view.@editor.render(Screen.new(b), Rect.new(0, 0, 90, 24), cursor: false, highlight: :request)
  (0...24).each do |y|
    (0...90).each do |x|
      return b.fg_at(x, y) if b.grid[y][x] == '$'
    end
  end
  Gori::Tui::Color.default
end

# One header the OPERATOR types, appended to the head after the flip.
private def add_header(view : RepeaterView, text : String) : Nil
  view.@editor.goto_line(2) # the Host line
  view.@editor.end_of_line
  view.@editor.insert_newline
  text.each_char { |c| view.@editor.insert(c) }
end

describe "evidence env baselines across an env.syntax flip" do
  it "keeps a capture's `$id` literal when the grammar flips namespaced → bare" do
    with_env_fixture do
      view = with_env_syntax(Gori::Env::Syntax::Namespaced) do
        evidence_tab(graphql_request("$id"))
      end
      # The operator flips the grammar from another tab. The capture's bytes did not move.
      with_env_syntax(Gori::Env::Syntax::Bare) do
        sent = String.new(view.request_bytes)
        sent.should contain("query($id: ID!)")
        sent.should_not contain("SECRET-ID")
        first_sigil_fg(view).should_not eq(Theme.env_known)

        # …and the same buffer still substitutes what the OPERATOR writes into it after the
        # flip: withholding by buffer rather than by name is the other way to get this wrong.
        add_header(view, "X-Host: $HOST")
        String.new(view.request_bytes).should contain("X-Host: api.test")
      end
    end
  end

  it "keeps a capture's `$ENV.id` literal when the grammar flips bare → namespaced" do
    with_env_fixture do
      # Under the bare grammar these bytes hold a token named `ENV` and nothing else, so the
      # seed-time literal set was `{"ENV"}` — which says nothing about the `ENV.id` the painter
      # and the send path ask about once the grammar names namespaces.
      view = with_env_syntax(Gori::Env::Syntax::Bare) do
        evidence_tab(graphql_request("$ENV.id"))
      end
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        sent = String.new(view.request_bytes)
        sent.should contain("query($ENV.id: ID!)")
        sent.should_not contain("SECRET-ID")
        first_sigil_fg(view).should_not eq(Theme.env_known)

        add_header(view, "X-Host: $ENV.HOST")
        String.new(view.request_bytes).should contain("X-Host: api.test")
      end
    end
  end

  it "paints a DRAFT's token as resolvable in either grammar — the baseline is evidence-only" do
    with_env_fixture do
      view = RepeaterView.new
      view.restore("http://127.0.0.1", graphql_request("$id"), false, false, evidence: false)
      with_env_syntax(Gori::Env::Syntax::Bare) do
        first_sigil_fg(view).should eq(Theme.env_known)
        String.new(view.request_bytes).should contain("SECRET-ID")
      end
    end
  end

  it "carries the seed bytes into a DUPLICATED tab, so the clone answers the flip too" do
    with_env_fixture do
      src = with_env_syntax(Gori::Env::Syntax::Namespaced) do
        evidence_tab(graphql_request("$id"))
      end
      clone = RepeaterView.new
      clone.duplicate_from(src)
      with_env_syntax(Gori::Env::Syntax::Bare) do
        sent = String.new(clone.request_bytes)
        sent.should contain("query($id: ID!)")
        sent.should_not contain("SECRET-ID")
        # The clone's own editor knows the provenance as well: copying the DERIVED name set
        # left it with nothing to withhold, so a duplicated capture painted its `$id` as a
        # variable it was not sending.
        first_sigil_fg(clone).should_not eq(Theme.env_known)
      end
    end
  end
end

# The editor half of the same seam, at the unit it lives in: the set is re-derived from the bytes
# on `Env.highlight_rev`, which every `Settings.env_syntax=` bumps.
describe "TextArea#env_literal_source=" do
  it "re-derives the literal keys under the grammar in force when they are read" do
    with_env_fixture do
      ta = TextArea.new(%({"q":"$ENV.id"}))
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        ta.env_literal_source = ta.text
        # Namespaced: the reference is `ENV.id`, and both spellings are withheld.
        ta.@env_literal_names.should eq(Set{"ENV.id", "id"})
      end
      with_env_syntax(Gori::Env::Syntax::Bare) do
        b = MemoryBackend.new(60, 6)
        ta.render(Screen.new(b), Rect.new(0, 0, 60, 6), cursor: false, highlight: :request)
        # Bare: the same bytes hold a token named `ENV`, and that is what has to be withheld
        # now. A set frozen at seed time would still be answering the other grammar.
        ta.@env_literal_names.should eq(Set{"ENV"})
      end
    end
  end

  it "leaves a hand-assigned set alone — it has no bytes to re-derive from" do
    with_env_fixture do
      ta = TextArea.new("$id")
      ta.env_literal_names = Set{"id"}
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        ta.@env_literal_names.should eq(Set{"id"})
      end
    end
  end
end
