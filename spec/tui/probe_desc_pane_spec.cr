require "../spec_helper"
require "file_utils"
require "../support/memory_backend"
require "../support/fake_host"

include Gori::Tui

# The Probe detail's DESCRIPTION pane.
#
# `Probe.remediation` writes a sentence per rule, and the detail gave it ONE `width:`-capped
# row of the meta block. On a normal-width pane every rule but the tersest ended in `…`, so
# text that was in the binary and on the screen could not be read — and, being a `screen.text`
# call rather than a pane, could not be scrolled to, selected, or copied either.
#
# It is now a `ReadPane` in a card of its own: it takes focus (`⇥`, or `↓` off the last
# affected URL), takes a caret and a selection, and answers the detail's read verbs — which is
# what puts the remediation text on the clipboard through `y` and the space menu's Copy. It
# takes no edit at all; `ReadPane` has no edit path, which is the point rather than a limit.

private PROBE_DESC_CA = File.tempname("gori-probe-desc-ca")
Spec.after_suite { FileUtils.rm_rf(PROBE_DESC_CA) }

private def with_session(&)
  root = File.tempname("gori-probe-desc")
  Dir.mkdir_p(root)
  begin
    project = Gori::ProjectRegistry.new(root).temp("probedesc")
    session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
      Gori::Proxy::Tls::CertAuthority.load_or_create(PROBE_DESC_CA), Gori::Verbs.registry, project)
    begin
      yield FakeHost.new(session), session
    ensure
      session.close
    end
  ensure
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def key(k : Termisu::Input::Key, mods : Termisu::Input::Modifier = :none,
                char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, mods, char)
end

private UP       = -> { key(Termisu::Input::Key::Up) }
private DOWN     = -> { key(Termisu::Input::Key::Down) }
private SHIFT_UP = -> { key(Termisu::Input::Key::Up, :shift) }
private SHIFT_DN = -> { key(Termisu::Input::Key::Down, :shift) }

# An open Probe detail on a finding with `urls` affected URLs, driven through the controller
# so the ⇥ ring and the key arms are exercised the way the shell reaches them.
private def detail(session, urls = 3, &)
  store = session.store
  urls.times do |i|
    store.upsert_probe_issue(Gori::Probe::Detection.new(
      "missing_hsts", "headers", "a.test", "https://a.test/page/#{i}",
      "Strict-Transport-Security missing", Gori::Store::Severity::Medium))
  end
  yield store
end

private def controller(host, store) : ProbeController
  ctl = ProbeController.new(host)
  ctl.view.reload(store)
  ctl.view.open_detail(store).should be_true
  ctl
end

private def draw(view, w = 80, h = 20, focused = true) : {MemoryBackend, Rect}
  backend = MemoryBackend.new(w, h)
  screen = Screen.new(backend)
  inner = uninitialized Rect
  BodyChrome.framed(screen, Rect.new(0, 0, w, h), true) do |r|
    inner = r
    view.render(screen, r, focused)
  end
  {backend, inner}
end

private def row_of(backend, text : String) : Int32
  (0...backend.size[1]).each { |y| return y if backend.row(y).includes?(text) }
  raise "#{text.inspect} is not on the rendered grid"
end

# Every row the DESCRIPTION card drew, joined — the text as an operator can actually read it.
private def desc_text(backend, inner, view) : String
  body = view.desc_rect(inner).not_nil!
  (body.y...body.bottom).map { |y| backend.row(y)[body.x, body.w].rstrip }.reject(&.empty?).join
end

describe "the Probe detail's DESCRIPTION pane" do
  describe "the text is readable at all" do
    it "shows the whole remediation sentence instead of ending it in an ellipsis" do
      with_session do |host, session|
        detail(session) do |store|
          ctl = controller(host, store)
          backend, inner = draw(ctl.view)
          shown = desc_text(backend, inner, ctl.view)
          full = Gori::Probe.remediation("missing_hsts")
          # The complaint this pane exists to answer. The meta row capped at `rect.w - 2` and
          # `Screen#text` ellipsizes, so the tail was simply gone.
          full.size.should be > 60 # else this rule would not have demonstrated the bug
          shown.should eq(full)
          shown.includes?('…').should be_false
        end
      end
    end

    it "reclaims the meta row the one-line hint occupied" do
      with_session do |host, session|
        detail(session) do |store|
          ctl = controller(host, store)
          # `DETAIL_HEAD_ROWS` went 5 → 4: the remediation row left the meta block for a pane,
          # so the cards start one row higher and the URL list is a row TALLER than before,
          # not shorter. A pane that cost the list rows would be a bad trade.
          ProbeView::DETAIL_HEAD_ROWS.should eq(4)
          aff, desc = ctl.view.detail_split(Rect.new(1, 1, 78, 18))
          aff.y.should eq(1 + ProbeView::DETAIL_HEAD_ROWS)
          desc.y.should eq(aff.bottom)
          desc.bottom.should eq(19)
          desc.h.should eq(ProbeView::DESC_VISIBLE + 2)
        end
      end
    end

    it "names an absent description rather than drawing an empty card" do
      with_session do |host, session|
        # A custom rule whose description was cleared: `detail_hint` answers "", and `ReadPane`
        # draws nothing for empty text — a bordered card with a blank interior reads as a pane
        # that failed to load.
        store = session.store
        id = store.insert_probe_custom_rule("quiet", "", "response", "header", "string",
          "X-Quiet", Gori::Store::Severity::Low)
        store.upsert_probe_issue(Gori::Probe::Detection.new(
          "custom_p_#{id}", "custom", "a.test", "https://a.test/", "Quiet",
          Gori::Store::Severity::Low))
        ctl = controller(host, store)
        ctl.view.detail_copy_all.should_not be_empty # the URL pane still has its row
        ctl.pane_advance(1)
        ctl.view.detail_copy_all.should be_empty # …and the description genuinely has none
        backend, _ = draw(ctl.view)
        row_of(backend, "(no description)").should be >= 0
      end
    end
  end

  describe "focus" do
    it "walks the two panes with ⇥ and wraps, never handing focus to the tab bar" do
      with_session do |host, session|
        detail(session) do |store|
          ctl = controller(host, store)
          ctl.view.detail_focus.should eq(:affected)
          # `false` is how a view tells `Runner#focus_advance` to hand focus to the TAB BAR,
          # while the detail's key arm is gated on body focus — so a false here strands the
          # detail on screen with a dead keyboard. This arm used to SWALLOW ⇥ (returning true
          # with nothing to move to); now it moves, and still never answers false.
          ctl.pane_advance(1).should be_true
          ctl.view.detail_focus.should eq(:desc)
          ctl.pane_advance(1).should be_true
          ctl.view.detail_focus.should eq(:affected) # wraps
          ctl.pane_advance(-1).should be_true
          ctl.view.detail_focus.should eq(:desc) # ⇧⇥ wraps the other way
        end
      end
    end

    it "is visible: the focused card's border lights and the other dims" do
      with_session do |host, session|
        detail(session) do |store|
          ctl = controller(host, store)
          on_aff, _ = draw(ctl.view)
          ctl.pane_advance(1)
          on_desc, _ = draw(ctl.view)
          ay = row_of(on_aff, "AFFECTED URLS")
          dy = row_of(on_aff, "DESCRIPTION")
          # The whole reason a focus move must draw something: with both borders painted from
          # the pane-level `focused` the ring would move silently.
          on_aff.fg_at(1, ay).should eq(Frame.pane_border(true))
          on_aff.fg_at(1, dy).should eq(Frame.pane_border(false))
          on_desc.fg_at(1, ay).should eq(Frame.pane_border(false))
          on_desc.fg_at(1, dy).should eq(Frame.pane_border(true))
        end
      end
    end

    it "crosses on ↓ off the last URL and ↑ off the first description row" do
      with_session do |host, session|
        detail(session) do |store|
          ctl = controller(host, store)
          draw(ctl.view)                             # the panes must have been measured for the wrap-aware edge tests
          2.times { ctl.handle_body_key(DOWN.call) } # onto the last of three URLs
          ctl.view.affected_at_bottom?.should be_true
          ctl.handle_body_key(DOWN.call).should be_true
          ctl.view.detail_focus.should eq(:desc) # ↓ had nowhere else to go
          ctl.handle_body_key(UP.call).should be_true
          ctl.view.detail_focus.should eq(:affected) # …and ↑ comes back
        end
      end
    end

    it "crosses off a WRAPPED last URL, where the caret cannot advance any further" do
      with_session do |host, session|
        store = session.store
        2.times do |i|
          store.upsert_probe_issue(Gori::Probe::Detection.new(
            "missing_hsts", "headers", "a.test", "https://a.test/page/#{i}",
            "Strict-Transport-Security missing", Gori::Store::Severity::Medium))
        end
        # A URL long enough to take three drawn rows on a 76-column card.
        long = "https://a.test/" + ("segment/" * 25)
        store.upsert_probe_issue(Gori::Probe::Detection.new(
          "missing_hsts", "headers", "a.test", long,
          "Strict-Transport-Security missing", Gori::Store::Severity::Medium))
        ctl = controller(host, store)
        _, inner = draw(ctl.view)
        body = ctl.view.affected_rect(inner).not_nil!
        (long.size // body.w).should be >= 2 # else this URL would not have wrapped

        2.times { ctl.handle_body_key(DOWN.call) } # onto the last URL, caret at column 0
        ctl.view.affected_url.should eq(long)
        # This pane's ↓ is `goto_line`, so the caret is ALREADY as far as it can go — the
        # wrapped remainder of this URL is the same entry, not a row to step onto. Asking the
        # visual question here answered "not at the bottom" forever, and `goto_line` had
        # already clamped: ↓ did nothing whatsoever on any finding whose last URL wrapped.
        ctl.view.affected_at_bottom?.should be_true
        ctl.handle_body_key(DOWN.call).should be_true
        ctl.view.detail_focus.should eq(:desc)
      end
    end

    it "does not cross on a ⇧arrow, so extending a selection cannot change panes" do
      with_session do |host, session|
        detail(session) do |store|
          ctl = controller(host, store)
          draw(ctl.view)
          2.times { ctl.handle_body_key(DOWN.call) }
          ctl.view.affected_at_bottom?.should be_true
          # A ⇧arrow is a selection gesture. Handing it across would abandon the selection it
          # is in the middle of building.
          ctl.handle_body_key(SHIFT_DN.call)
          ctl.view.detail_focus.should eq(:affected)
          ctl.pane_advance(1)
          ctl.handle_body_key(SHIFT_UP.call)
          ctl.view.detail_focus.should eq(:desc)
        end
      end
    end
  end

  describe "the read verbs follow focus" do
    it "copies the remediation text once DESCRIPTION holds focus" do
      with_session do |host, session|
        detail(session) do |store|
          ctl = controller(host, store)
          # The AFFECTED pane's own copy, unchanged.
          ctl.view.detail_copy_all.should eq((0...3).map { |i| "https://a.test/page/#{i}" }.join('\n'))
          ctl.pane_advance(1)
          # …and the reason the pane takes focus at all. `probe.copy` / the space menu's Copy
          # reach `detail_copy_all` through the same delegator, so this IS what `y` puts on the
          # clipboard.
          ctl.view.detail_copy_all.should eq(Gori::Probe.remediation("missing_hsts"))
          ctl.probe_detail_readable?.should be_true # the verb gate holds for BOTH panes
        end
      end
    end

    it "selects a line in whichever pane has focus" do
      with_session do |host, session|
        detail(session) do |store|
          ctl = controller(host, store)
          draw(ctl.view)
          ctl.pane_advance(1)
          ctl.view.detail_selection?.should be_false
          ctl.probe_detail_select_line
          ctl.view.detail_selection?.should be_true
          ctl.view.detail_copy_text.should eq(Gori::Probe.remediation("missing_hsts"))
          ctl.probe_detail_clear_selection
          ctl.view.detail_selection?.should be_false
        end
      end
    end

    it "answers no affected URL while DESCRIPTION has focus, so ↵ has nothing to open" do
      with_session do |host, session|
        detail(session) do |store|
          ctl = controller(host, store)
          ctl.view.affected_url.should eq("https://a.test/page/0")
          ctl.pane_advance(1)
          # `probe.open-affected` is gated on this. Without it the ↵ that opens a URL in
          # History would fire over a paragraph of remediation prose and open row 0's URL —
          # a key doing something the caret is nowhere near.
          ctl.view.affected_url.should be_nil
          ctl.probe_affected_url.should be_nil
        end
      end
    end

    it "sources the pane before a verb reads it, so a copy cannot come back empty" do
      with_session do |host, session|
        detail(session) do |store|
          ctl = controller(host, store)
          # NO render between opening the detail and the copy: `⇥` then `y` is a legitimate
          # order, and a `ReadPane` that has never been sourced answers `empty?` — which would
          # have put "" on the clipboard from a pane that was fully drawn on screen.
          ctl.pane_advance(1)
          ctl.view.detail_copy_all.should_not be_empty
        end
      end
    end
  end

  describe "the pointer" do
    it "focuses the card that was clicked and places that pane's caret" do
      with_session do |host, session|
        detail(session) do |store|
          ctl = controller(host, store)
          backend, inner = draw(ctl.view)
          desc_body = ctl.view.desc_rect(inner).not_nil!
          ctl.view.detail_click(inner, desc_body.x + 2, desc_body.y)
          ctl.view.detail_focus.should eq(:desc)
          # …and back, onto a specific URL row read off the grid rather than a pinned number.
          y = row_of(backend, "https://a.test/page/2")
          ctl.view.detail_click(inner, 4, y)
          ctl.view.detail_focus.should eq(:affected)
          ctl.view.affected_url.should eq("https://a.test/page/2")
        end
      end
    end

    it "leaves focus alone for a drag, so a selection cannot change panes mid-gesture" do
      with_session do |host, session|
        detail(session) do |store|
          ctl = controller(host, store)
          _, inner = draw(ctl.view)
          desc_body = ctl.view.desc_rect(inner).not_nil!
          # A drag that starts in AFFECTED and wanders into DESCRIPTION keeps extending the
          # selection it began; re-targeting would hand the anchor to the other pane.
          ctl.view.detail_click(inner, 4, ctl.view.affected_rect(inner).not_nil!.y)
          ctl.view.detail_click(inner, desc_body.x + 2, desc_body.y, selecting: true)
          ctl.view.detail_focus.should eq(:affected)
        end
      end
    end

    it "leaves focus alone for a press on the chrome between the cards" do
      with_session do |host, session|
        detail(session) do |store|
          ctl = controller(host, store)
          _, inner = draw(ctl.view)
          ctl.view.detail_pane_at(inner, inner.x + 2, inner.y).should be_nil # the meta block
          ctl.view.detail_click(inner, inner.x + 2, inner.y)
          ctl.view.detail_focus.should eq(:affected)
        end
      end
    end
  end

  describe "geometry" do
    it "never grants DESCRIPTION a row too short to draw a card with" do
      with_session do |host, session|
        detail(session) do |store|
          ctl = controller(host, store)
          # `Frame.card` needs two rows for its own frame, so a granted h == 1 paints nothing
          # and just costs AFFECTED the row. Sweep the band where the clamp is active.
          (4..14).each do |h|
            aff, desc = ctl.view.detail_split(Rect.new(0, 0, 40, h))
            desc.h.should_not eq(1)
            desc.y.should eq(aff.bottom)
            desc.bottom.should eq(h)
            aff.y.should eq({ProbeView::DETAIL_HEAD_ROWS, h}.min)
          end
        end
      end
    end

    it "keeps both cards inside the detail pane at every size" do
      with_session do |host, session|
        detail(session) do |store|
          ctl = controller(host, store)
          {40, 60, 80, 120}.each do |w|
            (4..24).each do |h|
              inner = Rect.new(1, 1, w - 2, h - 2)
              aff, desc = ctl.view.detail_split(inner)
              {aff, desc}.each do |c|
                c.x.should be >= inner.x
                c.right.should be <= inner.right
                c.y.should be >= inner.y
                c.bottom.should be <= inner.bottom
              end
            end
          end
        end
      end
    end
  end
end
