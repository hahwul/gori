require "../support/tui_contract"

include Gori::Tui

MINER_FOOTER_CA = File.tempname("gori-footer-ca")
Spec.after_suite { FileUtils.rm_rf(MINER_FOOTER_CA) }

# One persisted miner session, so the controller reconciles a view that is NOT running —
# `start_session` would send. Same shape as `session_rename_refusal_spec`'s helper.
private def with_miner_session(&)
  # Opened BEFORE the begin, like `TuiContract.with_session`: a `session = nil` placeholder
  # only exists to widen the ensure's scope and reads as a useless assignment.
  root = File.tempname("gori-footer")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("footer")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(MINER_FOOTER_CA), Gori::Verbs.registry, project)
  begin
    req = "GET /orders HTTP/1.1\r\nHost: shop.test\r\n\r\n"
    session.store.insert_miner_session("https://shop.test", req.to_slice, false, nil, "{}", nil, 0).should be > 0
    yield FakeHost.new(session)
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# The footer's DESTINATION word, which the roster contract next door cannot check: it can
# see that a line names an exit, not that the exit it names is where the key goes. These are
# the three panes where the two disagreed.
#
# All three are the same defect wearing different clothes — a hint asserting something about
# a key that the handler does not do — and all three read as the operator's mistake, because
# the line on screen is the only thing telling them what should have happened.
describe "footer hints name the destination the key actually reaches" do
  it "the Colormarker colours pane says `esc rules`, and the rule list says `esc tabs`" do
    # `handle_colors_key` puts focus back on the RULES list; the line said "esc tabs", which
    # is where the SECOND press lands. `handle_rules_key` goes to the tab bar and said nothing.
    TuiContract.with_session("colormarker-exit") do |session|
      host = TuiContract::Host.new(session)
      host.tab = :colormarker
      ctl = ColormarkerController.new(host)
      TuiContract.render(ctl)
      ctl.body_hint(:body).should contain("esc tabs")
      ctl.body_hint(:body).should_not contain("esc rules")

      ctl.pane_advance(1).should be_true # ⇥ onto the colours pane
      ctl.body_hint(:body).should contain("esc rules")
      ctl.body_hint(:body).should_not contain("esc tabs")
    end
  end

  it "the Colormarker rule list drops `↹ colours` when the colours pane is not drawn" do
    # `@colors_shown` comes off the render path, gates `pane_advance`, and is false on a
    # terminal too short to host the pane — where ⇥ is a no-op the line kept advertising.
    TuiContract.with_session("colormarker-short") do |session|
      host = TuiContract::Host.new(session)
      host.tab = :colormarker
      ctl = ColormarkerController.new(host)
      TuiContract.render(ctl)
      ctl.body_hint(:body).should contain("↹ colours")

      short = MemoryBackend.new(60, 6)
      ctl.render_body(Screen.new(short), Rect.new(0, 0, 60, 6), :body)
      ctl.pane_advance(1).should be_false # the ring has one pane, so ⇥ does nothing
      ctl.body_hint(:body).should_not contain("↹ colours")
    end
  end

  it "the Miner names the run key while idle and the stop key while mining" do
    # `{mine.stop}` was named unconditionally: an idle session advertised the one key that
    # does nothing there and hid `^R`, the key that starts the mine, behind the card badge.
    with_miner_session do |host|
      ctl = MinerController.new(host)
      v = ctl.current_view.should_not be_nil

      v.running?.should be_false
      ctl.body_hint(:body).should contain(" run")
      ctl.body_hint(:body).should_not contain(" stop")

      v.begin_run
      v.running?.should be_true
      ctl.body_hint(:body).should contain(" stop")
      ctl.body_hint(:body).should_not contain(" run")
    end
  end
end
