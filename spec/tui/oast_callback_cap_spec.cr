require "../spec_helper"
require "../support/memory_backend"
require "file_utils"

include Gori::Tui

# The OAST callbacks buffer is the ONE result list in the TUI whose growth is paced by a
# NETWORK PEER rather than by the operator.
#
# `OastController#apply_callback` appended one `CbRow` per interaction — each holding the full
# `raw_request` AND `raw_response` strings — with no cap and no eviction anywhere in the file,
# and `@seen` interned one uid per row in lockstep. Nothing trimmed either; the only thing that
# ever cleared them was a full `reload`, which then re-materialised the WHOLE table
# (`oast_callbacks_since(0)` has no LIMIT) and handed it straight back.
#
# The operator does not fill this one. interact.sh-class domains attract unsolicited
# third-party scanner traffic, and the poller ingests at `POLL_INTERVAL = 5.seconds` for as
# long as the listener lives — so retained bytes were a function of how long the listener was
# left up and how popular the provider's domain is, neither of which the operator controls.
# Every sibling buffer in this layer is bounded (`Notifications::CAP` 100, `Jobs::CAP` 50,
# `FuzzerView::RESULT_CAP` 5000); this one was the outlier.
#
# The fix is a WINDOW, not a destructive trim: the newest `CALLBACK_CAP` rows are held in
# memory, every evicted row is still in `oast_callbacks`, and the pane SAYS SO — a silent cap
# in the one tab whose whole job is evidence is its own defect. These examples pin all three
# halves: the buffer stops growing, `@seen` stops growing with it, and the operator can see it.

# The narrow shell facade a controller is given. Everything here is inert except `session`,
# `jobs` and `notifications` — the only members the callback drain touches — because a
# controller reaches the shell ONLY through this module, so stubbing it is stubbing the shell.
# File-local rather than shared with repeater_refusal_inline_spec's identical double: `Host` is
# ~30 abstract methods and a shared support double would be a fourth file to keep in sync with
# the module every time it grows.
private class FakeHost
  include Gori::Tui::Host

  getter statuses = [] of String

  def initialize(@session : Gori::Session)
    @jobs = Gori::Tui::Jobs.new
    @notifications = Gori::Tui::Notifications.new
  end

  def session : Gori::Session
    @session
  end

  def jobs : Gori::Tui::Jobs
    @jobs
  end

  def notifications : Gori::Tui::Notifications
    @notifications
  end

  def status(message : String) : Nil
    @statuses << message
  end

  def request_overlay(kind : Symbol) : Nil
  end

  def request_focus(pane : Symbol) : Nil
  end

  def focus_body : Nil
  end

  def switch_tab(tab : Symbol) : Nil
  end

  def goto_tab(tab : Symbol) : Nil
  end

  def open_palette : Nil
  end

  def open_help_query(surface : Symbol) : Nil
  end

  def open_space_menu : Nil
  end

  def open_fuzz_set_editor(edit_index : Int32?) : Nil
  end

  def open_fuzz_advanced_editor : Nil
  end

  def reconfigure_sequence : Nil
  end

  def open_scope_rule_editor(edit_id : Int64?, kind : String, match_type : String, pattern : String) : Nil
  end

  def open_custom_rule_editor(rule : Gori::Probe::CustomRule?) : Nil
  end

  def open_rewriter_rule_editor(rule : Gori::Store::MatchRule?) : Nil
  end

  def open_colormarker_rule_editor(rule : Gori::Store::ColorRule?) : Nil
  end

  def open_colormarker_color_editor(color : Gori::Settings::ColormarkerColor?) : Nil
  end

  def open_extract_rule_editor(rule : Gori::Store::ExtractRule?) : Nil
  end

  def open_chain_save : Nil
  end

  def open_chain_load : Nil
  end

  def open_oast_provider_editor(provider : Gori::Oast::ProviderConfig?) : Nil
  end

  def confirm(title : String, message : String, *, confirm_label : String, danger : Bool,
              return_to : Symbol = :none, &action : -> Nil) : Nil
    action.call # no modal in a spec: a confirmed action runs straight through
  end

  def overlay : Symbol
    :none
  end

  def active_tab : Symbol
    :oast
  end

  def focus : Symbol
    :body
  end

  def reveal? : Bool
    false
  end

  def toggle_reveal : Nil
  end

  def pretty? : Bool
    false
  end

  def toggle_pretty : Nil
  end

  def toggle_scope_lens : Nil
  end

  def toggle_sandbox : Nil
  end

  def apply_project_network(bind_host : String, bind_port : Int32, upstream : String,
                            connect_secs : Int32, io_secs : Int32, capture_mib : Int32) : String
    ""
  end
end

# The CA is the one slow part of standing a Session up (a root keypair), and it is pure
# infrastructure here — no example asserts anything about it — so it is built once.
private CAP_CA_ROOT = File.tempname("gori-oast-cap-ca")
Spec.after_suite { FileUtils.rm_rf(CAP_CA_ROOT) }

# A real Session (the controller reads `session.store` on construction and on every fold) with
# ONE persisted OAST session row, so the folded rows get a real session_id and a real label —
# the same path a reopened project takes, no test-only seam.
private def with_oast_controller(&)
  root = File.tempname("gori-oast-cap")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("oastcap")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(CAP_CA_ROOT), Gori::Verbs.registry, project)
  begin
    sid = session.store.insert_oast_session(nil, "interactsh", "https://oast.test",
      "c0rr3lat10n", "s3cret", nil, nil)
    host = FakeHost.new(session)
    yield OastController.new(host), host, session, sid
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# One interaction as the poller would deliver it. The raw sides are deliberately non-trivial —
# they are the bytes the unbounded buffer was retaining, and the reason a row is not free.
private def interaction(n : Int32) : Gori::Oast::Interaction
  Gori::Oast::Interaction.new(
    unique_id: "uid-#{n.to_s.rjust(6, '0')}",
    protocol: "dns",
    method: nil,
    source_ip: "203.0.113.#{n % 256}",
    full_id: "#{n.to_s.rjust(6, '0')}.oast.test",
    raw_request: ";; QUESTION SECTION:\n;#{n.to_s.rjust(6, '0')}.oast.test. IN A\n" + ("x" * 256),
    raw_response: ";; ANSWER SECTION:\n#{n.to_s.rjust(6, '0')}.oast.test. 60 IN A 203.0.113.1",
    at: Time.unix(1_700_000_000_i64 + n))
end

# Push `count` interactions through the SAME path the poll fiber uses: the events channel plus
# `drain_events` on the main fiber. The channel holds 256 and one drain handles DRAIN_CAP (512),
# so this interleaves rather than filling the channel — exactly what a real flood does across
# consecutive run-loop ticks.
private def flood(controller : OastController, sid : Int64, count : Int32, from : Int32 = 0) : Nil
  (from...(from + count)).each do |n|
    controller.@oast_events.send(Gori::Oast::CallbackEvent.new(sid, interaction(n)))
    controller.drain_events if (n - from + 1) % 200 == 0
  end
  controller.drain_events
end

# What the operator actually sees in the CALLBACKS card, which is the whole point of capping
# visibly rather than silently.
private def callbacks_pane(controller : OastController) : String
  backend = MemoryBackend.new(120, 40)
  controller.render_body(Screen.new(backend), Rect.new(0, 0, 120, 40), :body)
  (0...40).map { |y| backend.row(y) }.join("\n")
end

describe "Gori::Tui::OastController — the callback buffer is a bounded window" do
  it "stops growing past CALLBACK_CAP, and stops @seen growing with it" do
    over = 50
    total = OastController::CALLBACK_CAP + over
    with_oast_controller do |controller, _host, session, sid|
      flood(controller, sid, total)

      # The defect: this was `total`, and one CbRow carries the full raw request AND response.
      controller.@callbacks.size.should eq(OastController::CALLBACK_CAP)
      # @seen interned one uid per row in lockstep — capping the rows alone would have left
      # the same unbounded growth behind, just with a smaller constant.
      controller.@seen.values.sum(&.size).should eq(OastController::CALLBACK_CAP)
      controller.@evicted.should eq(over)

      # A WINDOW, not a destructive trim: not one interaction left the project DB.
      session.store.oast_callbacks_since(0_i64).size.should eq(total)
      # …and the window is over the NEWEST rows, which is what makes eviction survivable:
      # a callback that arrives late can be the one that proves the vuln.
      uids = controller.@callbacks.map(&.uid)
      uids.last.should eq("uid-#{(total - 1).to_s.rjust(6, '0')}")
      uids.includes?("uid-000000").should be_false
    end
  end

  it "tells the operator the pane is a window — a silent cap in an evidence tool is its own defect" do
    with_oast_controller do |controller, host, _session, sid|
      flood(controller, sid, OastController::CALLBACK_CAP + 50)

      # Standing marker in the card title: the count must not read as "this is all there is".
      pane = callbacks_pane(controller)
      pane.should contain("CALLBACKS (#{OastController::CALLBACK_CAP} of #{OastController::CALLBACK_CAP + 50})")
      pane.should contain("50 older kept in the project DB")

      # And a one-time note, because the callbacks that get evicted are the ones that arrived
      # while the operator was on another tab.
      capped = host.notifications.all.select(&.message.includes?("newest #{OastController::CALLBACK_CAP}"))
      capped.size.should eq(1)
      capped.first.level.should eq(:warn)
    end
  end

  it "says so in the no-match empty state too, so a filter miss is not read as evidence of absence" do
    with_oast_controller do |controller, _host, _session, sid|
      flood(controller, sid, OastController::CALLBACK_CAP + 50)
      controller.start_cb_filter
      "203.0.113.999".each_char do |ch| # a source IP no interaction in this flood carries
        controller.handle_cb_filter_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerA, char: ch))
      end

      pane = callbacks_pane(controller)
      pane.should contain("no callbacks match")
      # Without this the operator filters for the source IP they care about, reads "no match",
      # and concludes it never hit — when the row is in the table the filter never saw.
      pane.should contain("filter covers the newest #{OastController::CALLBACK_CAP} only")
      pane.should contain("50 older are in the project DB")
    end
  end

  it "keeps the window (and the marker) across a tab revisit, which re-reads the whole table" do
    over = 50
    total = OastController::CALLBACK_CAP + over
    with_oast_controller do |controller, _host, _session, sid|
      flood(controller, sid, total)
      controller.on_enter # full reload: clears everything and re-folds the WHOLE table

      controller.@callbacks.size.should eq(OastController::CALLBACK_CAP)
      controller.@seen.values.sum(&.size).should eq(OastController::CALLBACK_CAP)
      # Recomputed from the table, not carried across — a revisit must not inflate the count.
      controller.@evicted.should eq(over)
      callbacks_pane(controller).should contain("#{over} older kept in the project DB")
    end
  end

  it "keeps dedup sound: a uid still inside the window never appends a second row" do
    with_oast_controller do |controller, _host, _session, sid|
      flood(controller, sid, OastController::CALLBACK_CAP + 50)
      before = controller.@callbacks.size

      # The newest interaction, re-announced by the provider on the next poll. Its uid is
      # inside the window, so @seen still holds it — trimming the OLD end is what preserves
      # that, since reconcile only ever re-reads rows NEWER than the watermark.
      controller.@oast_events.send(
        Gori::Oast::CallbackEvent.new(sid, interaction(OastController::CALLBACK_CAP + 49)))
      controller.drain_events

      controller.@callbacks.size.should eq(before)
      controller.@evicted.should eq(50)
    end
  end

  it "reports the session's TOTAL hits, not the window's — a counter that walks backwards is worse than none" do
    total = OastController::CALLBACK_CAP + 50
    with_oast_controller do |controller, _host, _session, sid|
      flood(controller, sid, total)
      # @seen used to BE the hit count (its size is the job note's "N hits"); now that it is
      # windowed, the count is carried separately or the listener's progress would shrink as
      # it kept receiving.
      controller.@hits[sid].should eq(total)
    end
  end
end
