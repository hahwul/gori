require "../spec_helper"
require "file_utils"
require "../support/memory_backend"
require "../support/fake_host"

include Gori::Tui

# The Issues and Probe `/` bars were the last two with no completion, and they were a byte-for
# byte pair — which is why they are fixed and pinned together. Both already parse the whole
# boolean grammar through the shared `FilterAst`; what they lacked was the row that teaches it.
#
# Two things this file exists to hold, beyond "the row appears":
#
#   * The ROW SHIFT. A suggestion row only exists while the bar is being EDITED, so the column
#     header and every list row move down by one for exactly that state. Three sites had
#     `rect.y + 3` (Issues) / `+ 4` (Probe) written out by hand — `render_list` and both
#     hit-tests — so a row added without one `list_top` puts every click one row off, and only
#     while the bar is open. A render-only assertion never reaches that state.
#   * WHOSE grammar the row names. `QuerySuggest.render`'s default help source is
#     `QL::FIELD_HELP`, and `cold_hint`'s default text names `~regex` and `>= < on status size
#     dur`. Neither backend implements a regex and neither has a `size` or `dur` axis, so the
#     defaults would print a vocabulary the parser refuses — the defect b28aaaaa fixed on these
#     exact two bars, arriving from the hint row instead of the field list.

private def render(view, w = 100, h = 16) : MemoryBackend
  backend = MemoryBackend.new(w, h)
  view.render(Screen.new(backend), Rect.new(0, 0, w, h))
  backend
end

private def row_of(backend, text : String, h = 16) : Int32
  (0...h).each { |y| return y if backend.row(y).includes?(text) }
  -1
end

describe "the Issues filter bar's completion" do
  it "shifts the header and the rows down by one while the bar is open, render and hit-test together" do
    with_store do |store|
      store.insert_issue("SQLi in /login", Gori::Store::Severity::Critical, "api.demo.test", nil)
      view = IssuesView.new
      view.reload(store)
      rect = Rect.new(0, 0, 100, 16)

      closed = render(view)
      row_closed = row_of(closed, "SQLi in /login")
      row_closed.should eq(3) # bar, header, divider
      view.list_row_at(rect, 10, row_closed).should eq(0)

      view.start_query
      # A field with an empty value matches all (spec-pinned in `issues_query_spec`), so the
      # row is still on screen to be located — a token that filtered it out would make this
      # assert about the empty state instead of the shift.
      "severity:".each_char { |c| view.query_insert(c) }
      open = render(view)
      row_open = row_of(open, "SQLi in /login")
      # One row lower, because the suggestion row now sits between the bar and the header.
      row_open.should eq(row_closed + 1)
      # …and the click hit-test moved WITH it. This is the assertion the hand-written
      # `rect.y + 3` could not satisfy: it answered for the closed layout in both states.
      view.list_row_at(rect, 10, row_open).should eq(0)
      view.list_row_at(rect, 10, row_closed).should be_nil
    end
  end

  it "names what ↹ takes, and what it means, from THIS backend's help table" do
    with_store do |store|
      store.insert_issue("SQLi in /login", Gori::Store::Severity::Critical, "api.demo.test", nil)
      view = IssuesView.new
      view.reload(store)
      view.start_query
      "st".each_char { |c| view.query_insert(c) }

      backend = render(view)
      sugg = backend.row(1)
      sugg.should contain("status:")
      # `QL::FIELD_HELP` would call this an HTTP code with 5xx classes. It is a triage state,
      # and the bar is the only place most operators ever read that.
      sugg.should contain("triage state")
      sugg.should_not contain("5xx")
    end
  end

  it "offers the boolean operators no field pool can reach" do
    with_store do |store|
      store.insert_issue("x", Gori::Store::Severity::Low, "a.test", nil)
      view = IssuesView.new
      view.reload(store)
      view.start_query
      "NO".each_char { |c| view.query_insert(c) }
      # `NOT (` is the one form with zero discovery: `-` negates a TERM and cannot negate a
      # GROUP. Matched case-sensitively, so searching for the word "not" still works.
      view.query_suggestions.should contain("NOT (")
    end
  end

  it "keeps the standing hint to the grammar this backend actually has" do
    with_store do |store|
      store.insert_issue("x", Gori::Store::Severity::Low, "a.test", nil)
      view = IssuesView.new
      view.reload(store)

      idle = render(view).row(0)
      # Every field, `title:` included — the literal this replaced listed four of five and no
      # operator at all.
      Gori::Issues::Filter::ALIASES.each_key { |f| idle.should contain("#{f}:") }
      idle.should contain("-term excludes")

      view.start_query
      render(view).row(1).should contain("-term excludes")

      # The TAIL is asserted on the constant, not the drawn row: `cold_hint` deliberately lets
      # the terminal truncate everything past `-term excludes`, so a `should_not contain` on a
      # 100-column row would pass because the text was cut off rather than because it is absent.
      hint = IssuesView::QUERY_HINT
      hint.should contain("? reference")
      hint.should contain(">= < on severity cvss")
      hint.should_not contain("~regex")
      hint.should_not contain("dur")
      hint.should_not contain("size")
    end
  end

  it "stays quiet on a token the operator is deliberately free-texting" do
    with_store do |store|
      store.insert_issue("x", Gori::Store::Severity::Low, "a.test", nil)
      view = IssuesView.new
      view.reload(store)
      view.start_query
      "zzz".each_char { |c| view.query_insert(c) }
      view.query_suggestions.should be_empty
      render(view).row(1).strip.should be_empty
    end
  end

  it "opens the dropdown on ↓ and splices the highlighted candidate" do
    with_store do |store|
      store.insert_issue("x", Gori::Store::Severity::Low, "a.test", nil)
      view = IssuesView.new
      view.reload(store)
      view.start_query
      "s".each_char { |c| view.query_insert(c) }
      view.popup_open?.should be_false

      view.popup_down # opens on the first candidate
      view.popup_open?.should be_true
      view.popup_down # …and moves to the second
      view.query_complete(close: true).should be_true
      view.popup_open?.should be_false
      view.query.should eq("status:")
    end
  end

  it "completes a NEGATED field, which the old tokenizer could not" do
    with_store do |store|
      store.insert_issue("x", Gori::Store::Severity::Low, "a.test", nil)
      view = IssuesView.new
      view.reload(store)
      view.start_query
      "-sev".each_char { |c| view.query_insert(c) }
      view.query_complete.should be_true
      view.query.should eq("-severity:")
    end
  end

  it "re-derives the list on a word-delete, not just on a plain keystroke" do
    with_store do |store|
      store.insert_issue("SQLi in /login", Gori::Store::Severity::Critical, "api.demo.test", nil)
      store.insert_issue("Verbose error", Gori::Store::Severity::Low, "api.demo.test", nil)
      view = IssuesView.new
      view.reload(store)
      view.start_query
      "severity:critical".each_char { |c| view.query_insert(c) }
      one = render(view)
      one.contains?("SQLi in /login").should be_true
      one.contains?("Verbose error").should be_false

      # `query_edit` reached `LineEdit.apply` and then `QueryBarEdit`'s base no-op, so a ⌥⌫
      # changed the query and left the RESULTS exactly as they were — a gap older than the
      # dropdown, and invisible to any assertion that only read `#query`.
      view.query_edit(:delete_word)
      view.query.should eq("severity:")
      both = render(view)
      both.contains?("SQLi in /login").should be_true
      both.contains?("Verbose error").should be_true
    end
  end
end

describe "the Probe filter bar's completion" do
  it "shifts the header and the rows down by one while the bar is open, render and hit-test together" do
    with_store do |store|
      store.upsert_probe_issue(Gori::Probe::Detection.new(
        "missing_csp", "headers", "a.test", "https://a.test/", "Missing CSP", Gori::Store::Severity::Low))
      view = ProbeView.new
      view.reload(store)
      rect = Rect.new(0, 0, 100, 16)

      closed = render(view)
      row_closed = row_of(closed, "Missing CSP")
      row_closed.should eq(4) # MODE band, bar, header, divider
      view.list_row_at(rect, 10, row_closed).should eq(0)

      view.start_query
      "category:".each_char { |c| view.query_insert(c) }
      open = render(view)
      row_open = row_of(open, "Missing CSP")
      row_open.should eq(row_closed + 1)
      view.list_row_at(rect, 10, row_open).should eq(0)
      view.list_row_at(rect, 10, row_closed).should be_nil
    end
  end

  it "completes `category:` and describes it from THIS backend's table" do
    with_store do |store|
      store.upsert_probe_issue(Gori::Probe::Detection.new(
        "missing_csp", "headers", "a.test", "https://a.test/", "Missing CSP", Gori::Store::Severity::Low))
      view = ProbeView.new
      view.reload(store)
      view.start_query
      "cat".each_char { |c| view.query_insert(c) }

      sugg = render(view).row(2)
      sugg.should contain("category:")
      sugg.should contain("which check found it")
      view.query_complete.should be_true
      view.query.should eq("category:")
      view.query_suggestions.should eq(
        Gori::Probe::FILTER_CATEGORIES.map { |c| "category:#{c}" })
    end
  end

  it "keeps the standing hint to the grammar this backend actually has" do
    with_store do |store|
      store.upsert_probe_issue(Gori::Probe::Detection.new(
        "missing_csp", "headers", "a.test", "https://a.test/", "Missing CSP", Gori::Store::Severity::Low))
      view = ProbeView.new
      view.reload(store)
      idle = render(view).row(1)
      Gori::Probe::Filter::ALIASES.each_key { |f| idle.should contain("#{f}:") }
      idle.should contain("-term excludes")

      view.start_query
      render(view).row(2).should contain("-term excludes")
      hint = ProbeView::QUERY_HINT
      hint.should contain(">= < on severity")
      hint.should_not contain("~regex")
      hint.should_not contain("dur")
      hint.should_not contain("size")
    end
  end
end

# `Screen#text` clips to the SCREEN, not to the pane it was handed, so a row placed past the
# body silently overwrites the shell's chrome. `contract_render_bounds_spec` sweeps every
# controller for exactly this — but through `handle_body_key`, and `/` is a keymap verb that
# never reaches it (measured: every controller answers false to a bare `/`). So the ONE state
# this change introduces, a bar being edited, is invisible to that sweep and has to be pinned
# here, where `start_query` is reachable.
private class BoundsBackend < Gori::Tui::Backend
  getter writes = [] of {Int32, Int32}

  def initialize(@w : Int32, @h : Int32)
  end

  def put(x : Int32, y : Int32, grapheme : Char | String, fg : Gori::Tui::Color,
          bg : Gori::Tui::Color, attr : Gori::Tui::Attribute) : Nil
    @writes << {x, y}
  end

  def size : {Int32, Int32}
    {@w, @h}
  end
end

# Driven through `render_body`, the call the shell makes and the one `contract_render_bounds_spec`
# sweeps: `BodyChrome` insets the rect before the view ever sees it, so handing the view the
# body rect directly would manufacture strays production never has.
private def stray_sizes(ctl) : Array(String)
  out = [] of String
  [40, 41, 52, 80].each do |w|
    (8..26).each do |h|
      body = Layout.compute(w, h).body
      backend = BoundsBackend.new(w, h)
      ctl.render_body(Screen.new(backend), body, :body)
      bad = backend.writes.reject { |(x, y)| body.contains?(x, y) }
      unless bad.empty?
        out << "#{w}x#{h} body(#{body.x},#{body.y} #{body.w}x#{body.h}) #{bad.size} out, first #{bad.first}"
      end
    end
  end
  out
end

private def with_qsession(&)
  root = File.tempname("gori-qbounds")
  Dir.mkdir_p(root)
  ca = File.tempname("gori-qbounds-ca")
  begin
    project = Gori::ProjectRegistry.new(root).temp("qbounds")
    session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
      Gori::Proxy::Tls::CertAuthority.load_or_create(ca), Gori::Verbs.registry, project)
    begin
      yield FakeHost.new(session), session
    ensure
      session.close
    end
  ensure
    FileUtils.rm_rf(root)
    FileUtils.rm_rf(ca)
  end
end

describe "the filter bars stay inside the body while they are being edited" do
  it "keeps every Issues write inside the body rect with the bar open" do
    with_qsession do |host, session|
      store = session.store
      store.insert_issue("SQLi in /login", Gori::Store::Severity::Critical, "api.demo.test", nil)
      ctl = IssuesController.new(host)
      ctl.view.reload(store)
      stray_sizes(ctl).should be_empty # the closed baseline, so a stray below is the bar's
      ctl.view.start_query
      "severity:".each_char { |c| ctl.view.query_insert(c) }
      stray_sizes(ctl).should be_empty
    end
  end

  it "keeps every Probe write inside the body rect with the bar open" do
    with_qsession do |host, session|
      store = session.store
      store.upsert_probe_issue(Gori::Probe::Detection.new(
        "missing_csp", "headers", "a.test", "https://a.test/", "Missing CSP", Gori::Store::Severity::Low))
      ctl = ProbeController.new(host)
      ctl.view.reload(store)
      stray_sizes(ctl).should be_empty
      ctl.view.start_query
      "category:".each_char { |c| ctl.view.query_insert(c) }
      stray_sizes(ctl).should be_empty
    end
  end

  # The empty-set message is the other row the +1 shift pushed out, and its width has been
  # missing since it was written — the longest overran a 36-column interior at every height.
  it "clips the no-match message to the pane on both bars" do
    with_qsession do |host, session|
      store = session.store
      store.insert_issue("SQLi in /login", Gori::Store::Severity::Critical, "api.demo.test", nil)
      store.upsert_probe_issue(Gori::Probe::Detection.new(
        "missing_csp", "headers", "a.test", "https://a.test/", "Missing CSP", Gori::Store::Severity::Low))

      ictl = IssuesController.new(host)
      ictl.view.reload(store)
      ictl.view.start_query
      "zzzzzz".each_char { |c| ictl.view.query_insert(c) }
      stray_sizes(ictl).should be_empty

      pctl = ProbeController.new(host)
      pctl.view.reload(store)
      pctl.view.start_query
      "zzzzzz".each_char { |c| pctl.view.query_insert(c) }
      stray_sizes(pctl).should be_empty
    end
  end

  # And the same rule one level in, against the rect the VIEW is handed. Issues' suggestion row
  # sits at `rect.y + 1` where Probe's is at `rect.y + 2` (the MODE band owns Probe's first
  # row), so at the sizes the shell actually produces Issues' unguarded row lands on the body
  # card's own bottom border — inside `body`, and therefore invisible to the sweep above. A
  # view owes its rect at every height, which is what `pane_overspill_spec` asserts of the
  # geometry and this asserts of the writes.
  it "draws inside the rect it was handed at every height, both views" do
    with_store do |store|
      store.insert_issue("SQLi in /login", Gori::Store::Severity::Critical, "api.demo.test", nil)
      store.upsert_probe_issue(Gori::Probe::Detection.new(
        "missing_csp", "headers", "a.test", "https://a.test/", "Missing CSP", Gori::Store::Severity::Low))

      iview = IssuesView.new
      iview.reload(store)
      iview.start_query
      "severity:".each_char { |c| iview.query_insert(c) }

      pview = ProbeView.new
      pview.reload(store)
      pview.start_query
      "category:".each_char { |c| pview.query_insert(c) }

      strays = [] of String
      {"issues" => iview.as(Gori::Tui::IssuesView | Gori::Tui::ProbeView), "probe" => pview.as(Gori::Tui::IssuesView | Gori::Tui::ProbeView)}.each do |name, view|
        [40, 52, 80].each do |w|
          (1..10).each do |h|
            rect = Rect.new(0, 0, w, h)
            backend = BoundsBackend.new(w, 40)
            view.render(Screen.new(backend), rect, focused: true)
            bad = backend.writes.reject { |(x, y)| rect.contains?(x, y) }
            strays << "#{name} #{w}x#{h}: #{bad.size} out, first #{bad.first}" unless bad.empty?
          end
        end
      end
      strays.should be_empty
    end
  end
end

# `apply_filter` re-anchors the selection by id, so running it on a caret move leaves state
# identical — the cost is invisible to any assertion about the list. What IS observable is the
# gate, through the public hook it guards. `HistoryController` and `SitemapController` both
# write `schedule_query_reload if LineEdit.mutating?(act)` deliberately; these two bars did not,
# so Home/End/⌥←/⌥→ re-parsed the query and re-ran the predicate over every row — and in Probe
# `apply_filter` additionally re-selects `@all` by status, runs `recount` and applies the scope
# lens.
private class SpyIssuesView < Gori::Tui::IssuesView
  getter reloads = 0

  def query_edited : Nil
    @reloads += 1
    super
  end
end

private class SpyProbeView < Gori::Tui::ProbeView
  getter reloads = 0

  def query_edited : Nil
    @reloads += 1
    super
  end
end

describe "editing a filter bar" do
  it "re-derives the list on a text change and NOT on a caret move" do
    with_store do |store|
      store.insert_issue("SQLi in /login", Gori::Store::Severity::Critical, "api.demo.test", nil)
      store.insert_issue("Verbose error", Gori::Store::Severity::Low, "api.demo.test", nil)
      view = SpyIssuesView.new
      view.reload(store)
      view.start_query
      "severity:critical".each_char { |c| view.query_insert(c) }
      typed = view.reloads
      typed.should eq(17) # one per keystroke

      %i[home end word_left word_right].each { |act| view.query_edit(act) }
      view.query.should eq("severity:critical")
      view.reloads.should eq(typed) # four motions, no reload

      view.query_edit(:delete_word)
      view.reloads.should eq(typed + 1)
      view.query.should eq("severity:")
    end
  end

  it "holds for Probe's bar too, where a reload costs the most" do
    with_store do |store|
      store.upsert_probe_issue(Gori::Probe::Detection.new(
        "missing_csp", "headers", "a.test", "https://a.test/", "Missing CSP", Gori::Store::Severity::Low))
      view = SpyProbeView.new
      view.reload(store)
      view.start_query
      "category:headers".each_char { |c| view.query_insert(c) }
      typed = view.reloads

      %i[home end word_left word_right].each { |act| view.query_edit(act) }
      view.reloads.should eq(typed)
      view.query_edit(:delete_word)
      view.reloads.should eq(typed + 1)
    end
  end
end

describe "`?` on a filter bar opens THIS backend's reference" do
  it "routes Issues and Probe to their own surfaces, not to QL's" do
    root = File.tempname("gori-qhelp")
    Dir.mkdir_p(root)
    ca = File.tempname("gori-qhelp-ca")
    begin
      project = Gori::ProjectRegistry.new(root).temp("qhelp")
      session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
        Gori::Proxy::Tls::CertAuthority.load_or_create(ca), Gori::Verbs.registry, project)
      begin
        qmark = Termisu::Event::Key.new(Termisu::Input::Key::LowerA, char: '?')

        ihost = FakeHost.new(session)
        ictl = IssuesController.new(ihost)
        ictl.view.reload(session.store)
        ictl.view.start_query
        ictl.handle_query_key(qmark).should be_true
        ihost.help_query_surfaces.should eq([:issues])
        # It is the `?` arm, not the printable arm: the key must not land in the bar.
        ictl.view.query.should eq("")

        phost = FakeHost.new(session)
        pctl = ProbeController.new(phost)
        pctl.view.reload(session.store)
        pctl.view.start_query
        pctl.handle_query_key(qmark).should be_true
        phost.help_query_surfaces.should eq([:probe])
        pctl.view.query.should eq("")
      ensure
        session.close
      end
    ensure
      FileUtils.rm_rf(root)
      FileUtils.rm_rf(ca)
    end
  end
end
