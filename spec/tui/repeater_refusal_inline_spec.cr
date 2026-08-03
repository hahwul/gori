require "../spec_helper"
require "../support/memory_backend"
require "file_utils"

include Gori::Tui

# A REFUSED repeater send used to be handed to the same channel a background send fiber uses:
#
#     results.send({view, Repeater::Result.new(Bytes.new(0), nil, nil, 0_i64, reason)})
#
# — a bare, BLOCKING `Channel#send` made from the UI fiber, into an 8-slot buffer whose only
# CONSUMER is that same fiber. `Runner#drain_results` runs only after `drain_burst`, which
# handles up to `CHAR_DRAIN_CAP` (65_536) coalesceable events before returning, and Enter IS
# coalesceable (it carries `char: '\r'`). So a ninth refusal inside one input burst parked the
# whole TUI inside `Channel#send`: no input, no render, no drain, terminal left in raw/alt mode
# — while the proxy kept capturing on other fibers, so the process still looked alive. The
# trigger is ordinary: a tab whose target is refused (Sandbox on, or an EXCLUDE rule) plus a
# ten-line paste into the response pane, since `PasteNewline` drops only the LF of each CR-LF
# pair. The refusal path also returns BEFORE `view.inflight = true`, so the one-in-flight guard
# never engaged and every Enter re-entered the send.
#
# The asymmetry was the proof of intent: the three BACKGROUND sends beside these already used
# `select/when…/else` with "drop the late result instead of blocking this fiber forever". Only
# the three UI-fiber refusals were bare.
#
# The fix applies the refusal INLINE (`RepeaterController#apply_refusal`) — it never left the
# fiber that owns view state, so the channel round-trip bought nothing and cost the deadlock.
# Dropping it under `select/else` would have been the wrong trade the other way: a late result
# is redundant, a refusal is the operator's only proof the send did not happen.

# The narrow shell facade a controller is given. Everything here is inert except `session`,
# `jobs`, `notifications` and `status` — the only members the send paths touch — because a
# controller can reach the shell ONLY through this module, so stubbing it is stubbing the
# entire shell.
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
    :repeater
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
private CA_ROOT = File.tempname("gori-refusal-ca")
Spec.after_suite { FileUtils.rm_rf(CA_ROOT) }

private def shared_ca : Gori::Proxy::Tls::CertAuthority
  Gori::Proxy::Tls::CertAuthority.load_or_create(CA_ROOT)
end

# A real Session (store + scope + config + host overrides are all read by `repeater_plan`)
# with SANDBOX ON, one seeded repeater tab, and a controller over it. Sandbox is what makes
# every send refuse without a socket: `Outbound.interactive` waives the up-front gate but the
# per-send hard gate still answers `blocked by sandbox (out of scope)`.
private def with_refused_tab(request : String, target : String = "http://127.0.0.1:9/", &)
  root = File.tempname("gori-refusal")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("refusal")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    shared_ca, Gori::Verbs.registry, project)
  begin
    session.scope.enable_sandbox
    # Seeded through the store, then read back by the controller's constructor — the same path
    # a reopened project takes, so no test-only tab-creation seam is needed.
    session.store.insert_repeater(target, request.to_slice, false, true, nil, 0)
    host = FakeHost.new(session)
    yield RepeaterController.new(host), host
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# What the operator actually sees in the RESPONSE pane, which is the whole point of applying a
# refusal to the view at all.
private def response_pane(view : RepeaterView) : String
  view.focus_pane(:response)
  backend = MemoryBackend.new(120, 24)
  view.render(Screen.new(backend), Rect.new(0, 0, 120, 24))
  (0...24).map { |y| backend.row(y) }.join("\n")
end

private PLAIN_REQUEST = "GET /refused HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
private GROUP_REQUEST = "GET /one HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n%%%\r\nGET /two HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
private WS_REQUEST    = "GET /socket HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"

# Ten Enters is a ten-line paste; twelve is comfortably past the 8-slot buffer either way. The
# whole drive runs on its own fiber behind a timeout, because the defect this guards is a
# fiber that never returns — an unguarded example would hang the suite instead of failing it.
private def drive_sends_within(n : Int32, seconds : Int32 = 10, &block : -> Nil) : Nil
  done = Channel(Nil).new(1)
  spawn do
    n.times { block.call }
    done.send(nil)
  end
  receive_within(done, seconds, "#{n} refused sends to return (the UI fiber is parked in Channel#send)")
end

describe "Gori::Tui::RepeaterController — a refused send never blocks the UI fiber" do
  it "applies the refusal to the view immediately, without waiting for a drain" do
    # The precise behavioural statement of the fix, and the one that fails CLEANLY (not by
    # hanging) against the old code: the refusal is on the view before drain_results is ever
    # called, because it never went near a channel.
    with_refused_tab(PLAIN_REQUEST) do |controller, host|
      view = controller.current_view.not_nil!
      response_pane(view).should_not contain("sandbox")

      controller.repeater_send

      response_pane(view).should contain("blocked by sandbox")
      host.statuses.last.should contain("blocked by sandbox")
    end
  end

  it "still tells the shell a response pane changed, so ^F hits and the frame are refreshed" do
    # The one thing the channel hand-off did for us: a true `drain_results` is what makes the
    # Runner re-run `search_recompute` and mark the frame dirty. Inline application reports it
    # through the same return value, and reports it exactly once.
    with_refused_tab(PLAIN_REQUEST) do |controller, _|
      controller.drain_results.should be_false # nothing has happened yet
      controller.repeater_send
      controller.drain_results.should be_true  # the inline refusal is announced…
      controller.drain_results.should be_false # …and not re-announced forever
    end
  end

  it "survives 12 refusals in one input burst — the 8-slot buffer used to park the UI fiber on the 9th" do
    with_refused_tab(PLAIN_REQUEST) do |controller, host|
      # No drain between sends, exactly like a burst: `drain_results` runs only after
      # `drain_burst` has handled the WHOLE run of Enters.
      drive_sends_within(12) { controller.repeater_send }

      host.statuses.size.should eq(12)
      host.statuses.each(&.should(contain("blocked by sandbox")))
      response_pane(controller.current_view.not_nil!).should contain("blocked by sandbox")
    end
  end

  it "survives 12 refused WebSocket sends — the same bare send guarded @ws_results" do
    with_refused_tab(WS_REQUEST, target: "ws://127.0.0.1:9/socket") do |controller, host|
      controller.current_view.not_nil!.ws_mode?.should be_true # else this drives the HTTP path
      drive_sends_within(12) { controller.repeater_send }

      host.statuses.size.should eq(12)
      host.statuses.each(&.should(contain("ws repeater:")))
    end
  end

  it "survives 12 refused group sends — the same bare send guarded @group_results" do
    with_refused_tab(GROUP_REQUEST) do |controller, host|
      drive_sends_within(12) { controller.repeater_send_group }

      host.statuses.size.should eq(12)
      host.statuses.each(&.should(contain("send group:")))
      # A whole pipeline is refused together (all of it rides one connection), so the
      # transcript the view now holds is one refused row per request in the buffer.
      response_pane(controller.current_view.not_nil!).should contain("blocked by sandbox")
    end
  end

  it "leaves the tab re-sendable — a refusal is not an in-flight send" do
    # The refusal path deliberately does NOT set `view.inflight`: nothing is on the wire and no
    # `ensure` would ever clear the flag. With the send applied inline, each re-entered Enter
    # does bounded work and enqueues nothing, so re-entrancy is no longer a freeze vector.
    with_refused_tab(PLAIN_REQUEST) do |controller, host|
      controller.repeater_send
      controller.any_inflight?.should be_false
      controller.repeater_send
      host.statuses.size.should eq(2) # not "repeater already in flight…"
      host.statuses.last.should contain("blocked by sandbox")
    end
  end
end

describe "Gori::Tui::RepeaterController — minimize stop seam wiring" do
  # `Repeater::Minimize::Stop` is exercised against the engine in
  # repeater_minimize_stop_spec.cr; these two assert that the controller's exit paths still do
  # the job bookkeeping they always did, now that they also stop the run. With no minimize
  # running both are no-ops, which is the contract the Runner's unwind relies on.
  it "stop_all is a no-op with no minimize running" do
    with_refused_tab(PLAIN_REQUEST) do |controller, _|
      controller.stop_all
      controller.stop_all # idempotent — leave-project then quit
    end
  end

  it "close_repeater_tab closes the tab with no minimize running" do
    with_refused_tab(PLAIN_REQUEST) do |controller, _|
      controller.count.should eq(1)
      controller.close_repeater_tab
      controller.count.should eq(0)
      controller.empty?.should be_true
    end
  end
end
