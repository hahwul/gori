require "../spec_helper"
require "../support/memory_backend"

# The TWO-STAGE `$ENV.KEY` / `$BIND.NAME` completer (P2 of the namespaced-token change).
#
# Every example here runs under `with_env_syntax(:namespaced)`; the BARE contract lives in
# `spec/tui/text_area_spec.cr` and must not move, so the last example in this file re-asserts
# the bare path through the SAME helpers — the one thing a two-mode dropdown can get wrong and
# still look correct is answering the new grammar's rows in the old mode.
#
# Rows are read off a RENDERED screen rather than out of an accessor: the order, the labels and
# the hints are what the operator picks from, and an internal list can be right while the
# painted list is not (the namespace row's hint is prose that has to fit beside its label).

private def env_key(k : Termisu::Input::Key, char : Char? = nil)
  Termisu::Event::Key.new(k, Termisu::Input::Modifier::None, char)
end

# ENV = {HOST, TOKEN, TOKEN2}; BIND = {SESSION}, genuinely bound through an extract rule so
# `vars_for(Bind)` answers it — a hand-stuffed table would not exercise the masking policy.
private def with_env_fixture(&)
  saved_vars = Gori::Settings.env_vars
  saved_project = Gori::Settings.project_env_vars
  saved_prefix = Gori::Settings.env_prefix
  Gori::Settings.env_vars = [{"HOST", "api.test"}, {"TOKEN", "s3cr3t-value"}, {"TOKEN2", "other"}]
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

private def typed(text : String) : Gori::Tui::TextArea
  ta = Gori::Tui::TextArea.new
  ta.env_complete = true
  text.each_char { |c| ta.insert(c) }
  ta
end

# The painted dropdown, one stripped string per row, in the order the operator reads them.
# The caret sits on line 0, so the popup opens at row 1.
private def rows_of(ta : Gori::Tui::TextArea, w = 60, h = 14) : Array(String)
  b = MemoryBackend.new(w, h)
  ta.render(Gori::Tui::Screen.new(b), Gori::Tui::Rect.new(0, 0, w, h), cursor: true)
  (1...h).map { |y| b.row(y).strip }.reject(&.empty?)
end

# Just the token labels, in row order — the selection bar is stripped so the assertion reads as
# the list the operator sees rather than as the paint.
private def labels_of(ta : Gori::Tui::TextArea) : Array(String)
  rows_of(ta).map(&.split(' ').first.lstrip('▎'))
end

private def tab(ta : Gori::Tui::TextArea) : Bool
  ta.handle_env_complete_key(env_key(Termisu::Input::Key::Tab))
end

describe "TextArea env completion (namespaced)" do
  it "offers the namespace openers first, then every name flattened" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        ta = typed("$")
        ta.env_completing?.should be_true
        rows = rows_of(ta)
        # Openers in enum order (so the list does not reshuffle as vars are added), each with
        # its own description and COUNT — the operator's answer to "which of these has
        # anything in it".
        rows[0].should start_with("▎$ENV.")
        rows[0].should contain("build-time env vars · 3")
        rows[1].should start_with("$BIND.")
        rows[1].should contain("session bindings · 1")
        rows[2].should start_with("$GEN.")
        rows[2].should contain("per-request generators · #{Gori::Env::GENERATORS.size}")
        # Then the token rows, sorted {name, namespace} — so the SAME NAME in two namespaces
        # lands adjacent, which is the pair an operator most needs to tell apart. Namespace is
        # the tie-break, not the primary key: grouping by namespace would scatter `id` and
        # `ENV.id` to opposite ends of a long list.
        # Generator rows stay behind their opener on a bare `$`, or they would fill the
        # eight-row viewport and push the operator's own variables below the fold.
        rows[3..].map(&.split(' ').first).should eq([
          "$ENV.HOST", "$BIND.SESSION", "$ENV.TOKEN", "$ENV.TOKEN2",
        ])
      end
    end
  end

  it "masks a BIND value in the dropdown and shows an ENV value in the clear" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        rows = rows_of(typed("$"))
        rows.find(&.starts_with?("$ENV.HOST")).should_not be_nil
        rows.any?(&.includes?("api.test")).should be_true
        # A binding value came off the wire and is a credential: never printed in full, here
        # or anywhere else (`Env::Namespace#secret?`).
        rows.any?(&.includes?("SESSIONCOOKIEVALUE")).should be_false
      end
    end
  end

  it "accepts a namespace row and STAYS OPEN on that namespace's names" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        ta = typed("$E")
        rows_of(ta).size.should eq(1) # `$ENV.` alone: no name starts with E
        tab(ta).should be_true
        ta.text.should eq("$ENV.")
        # The whole point of the two stages: the popup reopens rather than making the operator
        # press `$` again to see what is inside the namespace they just chose.
        ta.env_completing?.should be_true
        labels_of(ta).should eq(["$ENV.HOST", "$ENV.TOKEN", "$ENV.TOKEN2"])
      end
    end
  end

  it "shows generator formats without minting preview values" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        ta = typed("$G")
        tab(ta).should be_true
        ta.text.should eq("$GEN.")
        rows = rows_of(ta)
        rows.find!(&.starts_with?("▎$GEN.ISO8601")).should contain("UTC RFC 3339 · per send")
        # The catalog outgrew the eight-row viewport (#1152): UUID sorts last and sits below the
        # fold until a letter narrows the list.
        rows.find!(&.starts_with?("$GEN.RANDOM_HEX")).should contain("128-bit hex · fresh per send")
        narrowed = rows_of(typed("$GEN.UU"))
        narrowed.find!(&.includes?("$GEN.UUID")).should contain("UUID v4 · fresh per send")
      end
    end
  end

  it "reaches a whole reference in two ↹ from a single letter" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        ta = typed("$E")
        tab(ta).should be_true
        tab(ta).should be_true
        ta.text.should eq("$ENV.HOST")
        ta.env_completing?.should be_false
      end
    end
  end

  it "keeps the cheap path: $TO ↹ costs the same keystrokes as bare mode did" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        ta = typed("$TO")
        # No namespace label starts with TO, so the two token rows are the whole list.
        labels_of(ta).should eq(["$ENV.TOKEN", "$ENV.TOKEN2"])
        tab(ta).should be_true
        ta.text.should eq("$ENV.TOKEN")
      end
    end
  end

  it "narrows to one namespace once the namespace is in the bytes" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        ta = typed("$B")
        tab(ta).should be_true
        ta.text.should eq("$BIND.")
        # BIND's table only — the operator has said which table they mean.
        labels_of(ta).should eq(["$BIND.SESSION"])
      end
    end
  end

  it "↓ then ↵ picks the second name inside a namespace" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        ta = typed("$ENV.TO")
        ta.handle_env_complete_key(env_key(Termisu::Input::Key::Down)).should be_true
        ta.handle_env_complete_key(env_key(Termisu::Input::Key::Enter)).should be_true
        ta.text.should eq("$ENV.TOKEN2")
        ta.env_completing?.should be_false
      end
    end
  end

  it "closes once the sole reference is written out in full" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        # Compared against the TYPED TOKEN TEXT, not the partial: a row's `insert` is a whole
        # spelling, so comparing it to `HOST` would never match and the popup would sit open
        # over a finished token forever.
        typed("$ENV.HOST").env_completing?.should be_false
        # Both namespaces, and a name that is a PREFIX of another: `$ENV.TOKEN2` is finished and
        # closes, while `$ENV.TOKEN` stays open because `TOKEN2` is still one ↹ away.
        typed("$BIND.SESSION").env_completing?.should be_false
        typed("$GEN.UUID").env_completing?.should be_false
        typed("$ENV.TOKEN2").env_completing?.should be_false
        typed("$ENV.TOKEN").env_completing?.should be_true
        # Bare mode reaches the same rule through its own match builder.
        with_env_syntax(Gori::Env::Syntax::Bare) do
          typed("$HOST").env_completing?.should be_false
          typed("$SESSION").env_completing?.should be_false
          typed("$TOKEN").env_completing?.should be_true
        end
      end
    end
  end

  it "upgrades a fully typed bare name in place" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        ta = typed("$SESSION")
        # `$SESSION` resolves nothing under this grammar, and the operator who typed it almost
        # certainly means the binding — so the row stays offered even though the name is
        # complete, and ↹ rewrites the whole token rather than appending to it.
        ta.env_completing?.should be_true
        tab(ta).should be_true
        ta.text.should eq("$BIND.SESSION")
      end
    end
  end

  it "opens nothing for a namespace that is not one" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        # `$X.` and `$X.TO` are ordinary text — an operator typing a dotted value must not get
        # a dropdown over it, which is why `.` is structure and never key material.
        typed("$X.").env_completing?.should be_false
        typed("$X.TO").env_completing?.should be_false
        typed("$1").env_completing?.should be_false
      end
    end
  end

  it "accepts the selected namespace row on a typed `.`" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        ta = typed("$EN")
        ta.handle_env_complete_key(env_key(Termisu::Input::Key::LowerA, '.')).should be_true
        ta.text.should eq("$ENV.")
        ta.env_completing?.should be_true
        # …and only for a namespace row: a `.` over a TOKEN row is a literal dot the editor
        # must receive, so the popup declines the key and lets it fall through.
        t2 = typed("$TO")
        t2.handle_env_complete_key(env_key(Termisu::Input::Key::LowerA, '.')).should be_false
      end
    end
  end

  it "leaves a lone `$.` as text — the dot accepts a namespace the operator STARTED" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        # On a bare sigil the popup is showing what COULD follow, not a choice: `$` + `.` is a
        # dollar and a full stop in ordinary prose (a price, a shell `$.`), and accepting the
        # first opener there wrote `$ENV.` into bytes about to be sent.
        ta = typed("$")
        ta.env_completing?.should be_true
        ta.handle_env_complete_key(env_key(Termisu::Input::Key::LowerA, '.')).should be_false
        ta.text.should eq("$") # the key fell through to the editor, which types the dot itself
        # One typed letter is all it takes to mean a namespace, and then `.` finishes it.
        t2 = typed("$E")
        t2.handle_env_complete_key(env_key(Termisu::Input::Key::LowerA, '.')).should be_true
        t2.text.should eq("$ENV.")
      end
    end
  end

  it "eats the structural dot when the caret is still inside the namespace run" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        ta = Gori::Tui::TextArea.new("$ENV.TOKEN")
        ta.env_complete = true
        ta.move(0, 3) # `$EN|V.TOKEN`
        # An edit is what refreshes the popup, so nudge the buffer and put it back: the caret
        # lands at col 3 with the rows derived from `$EN|V.TOKEN`.
        ta.insert('X')
        ta.backspace
        ta.env_completing?.should be_true
        tab(ta).should be_true
        # The namespace row replaces `$ENV.` INCLUDING the dot already in the buffer. One span
        # shared with the token rows produced `$ENV..TOKEN`.
        ta.text.should eq("$ENV.TOKEN")
      end
    end
  end

  it "takes back one accept per ⌃Z" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Namespaced) do
        ta = typed("$E")
        tab(ta).should be_true # → $ENV.
        tab(ta).should be_true # → $ENV.HOST
        ta.text.should eq("$ENV.HOST")
        ta.undo
        ta.text.should eq("$ENV.")
        ta.undo
        ta.text.should eq("$E")
      end
    end
  end

  it "still answers the BARE grammar in bare mode" do
    with_env_fixture do
      with_env_syntax(Gori::Env::Syntax::Bare) do
        ta = typed("$TO")
        # One flat list, no openers, no qualification — and `Env.display_vars`, so the bound
        # binding completes beside the env vars.
        labels_of(ta).should eq(["$TOKEN", "$TOKEN2"])
        tab(ta).should be_true
        ta.text.should eq("$TOKEN")
        typed("$SESSION").env_completing?.should be_false # fully typed, nothing to upgrade to
      end
    end
  end
end
