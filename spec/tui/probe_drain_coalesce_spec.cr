require "../spec_helper"
require "file_utils"

include Gori::Tui

# `ProbeController#drain_events` runs on the render fiber, once per run-loop tick, from EVERY
# tab. It used to do two unbounded things there: loop the analyzer channel with no per-tick
# ceiling (every sibling drain has one — `DRAIN_CAP` in the fuzzer/miner/sequencer/discover/
# oast controllers), and call `refresh_from_store` once PER IssueEvent — a full-table
# `probe_issues` SELECT plus filter and detail re-derive, the exact cost the Runner's own
# probe_generation poll already refuses to pay off-tab ("repainting the whole screen up to 20
# times a second" during an active scan).
#
# probe/event.cr has always promised the opposite — "the controller coalesces them into a
# single list reload per frame" — so these examples pin the promise: one reload per drain, no
# reload at all while Probe is not the active tab, and a bounded number of events per tick.

# The narrow shell facade a controller is given; everything here is inert except `session`,
# `notifications`, `status` and `active_tab` — the only members this drain touches. File-local
# for the same reason oast_callback_cap_spec's identical double is: `Host` is ~30 abstract
# methods, and a shared support double would be another file to keep in sync with the module.
private class FakeHost
  include Gori::Tui::Host

  getter statuses = [] of String
  property active_tab : Symbol = :probe

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
    action.call
  end

  def overlay : Symbol
    :none
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

# Counts the full-table reloads the drain triggers. Crystal has no `override`, so this
# deliberately shadows the base method and chains with `super` — the point is to observe how
# MANY times the real one runs, not to replace it.
private class SpyProbeController < Gori::Tui::ProbeController
  getter reloads : Int32 = 0

  def initialize(host : Gori::Tui::Host)
    super
    @reloads = 0
  end

  def refresh_from_store : Bool
    @reloads += 1
    super
  end
end

# The CA is the one slow part of standing a Session up (a root keypair) and no example asserts
# anything about it, so it is built once.
private PROBE_DRAIN_CA_ROOT = File.tempname("gori-probe-drain-ca")
Spec.after_suite { FileUtils.rm_rf(PROBE_DRAIN_CA_ROOT) }

private def with_probe_controller(&)
  root = File.tempname("gori-probe-drain")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("probedrain")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(PROBE_DRAIN_CA_ROOT), Gori::Verbs.registry, project)
  begin
    host = FakeHost.new(session)
    yield SpyProbeController.new(host), host, session
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def issue_event(n : Int32, summary : String? = nil) : Gori::Probe::IssueEvent
  Gori::Probe::IssueEvent.new("h#{n}.test", summary)
end

private def seed_issue(store : Gori::Store, n : Int32) : Nil
  store.upsert_probe_issue(Gori::Probe::Detection.new(
    "reflected_param", Gori::Probe::Category::ACTIVE, "h#{n}.test",
    "https://h#{n}.test/?q=1", "Reflected parameter",
    Gori::Store::Severity::Medium, "query (q)", n.to_i64))
end

describe "Gori::Tui::ProbeController#drain_events" do
  it "reloads the issue list ONCE per drain, not once per IssueEvent" do
    with_probe_controller do |controller, host, session|
      host.active_tab = :probe
      seed_issue(session.store, 1)
      before = controller.reloads

      8.times { |n| session.probe.events.send(issue_event(n)) }
      controller.drain_events.should be_true

      # The defect: eight events meant eight full-table SELECT + filter passes on the render
      # fiber. One drain is one reload now, exactly as probe/event.cr's contract says.
      (controller.reloads - before).should eq(1)
      # …and the reload really happened, so a delivered IssueEvent never leaves the view behind.
      controller.view.row_count.should eq(1)
    end
  end

  it "skips the reload entirely while Probe is not the active tab, and catches up on entry" do
    with_probe_controller do |controller, host, session|
      host.active_tab = :history
      seed_issue(session.store, 1)
      before = controller.reloads

      4.times { |n| session.probe.events.send(issue_event(n)) }
      # Still drained (the toast/badge work is unconditional — it is visible from any tab)…
      controller.drain_events.should be_true
      # …but the full-table read is the poll path's rule: not for a list nobody is looking at.
      (controller.reloads - before).should eq(0)
      controller.view.row_count.should eq(0)

      # The only way into the Probe tab is `focus_tab`, which runs on_enter — so the off-tab
      # skip is caught up before the list is ever painted.
      controller.on_enter
      controller.view.row_count.should eq(1)
    end
  end

  it "stops at DRAIN_CAP events per tick and finishes the rest on the next one" do
    prev_toast = Gori::Settings.notify_toast?
    begin
      Gori::Settings.notify_toast = true # the per-event status line is the drain's own counter
      with_probe_controller do |controller, host, session|
        host.active_tab = :probe
        total = Gori::Tui::ProbeController::DRAIN_CAP + 40
        ch = session.probe.events

        # The analyzer's channel holds 256, so the flood has to come from a producer fiber:
        # the per-event `insert_event` is a writer round-trip and therefore a yield point,
        # which is precisely how the uncapped loop could run far past one channel-full.
        spawn do
          total.times { |n| ch.send(issue_event(n, "reflected param on h#{n}.test")) }
        end
        Fiber.yield # let the producer fill the channel before the first tick

        controller.drain_events.should be_true
        first = host.statuses.size
        first.should be <= Gori::Tui::ProbeController::DRAIN_CAP
        first.should be < total # the defect: one tick swallowed the whole flood

        # Nothing is dropped — the remainder is drained on subsequent ticks, 50 ms apart.
        20.times do
          break if host.statuses.size >= total
          controller.drain_events
          Fiber.yield # stands in for the run loop's tick sleep, so the producer can refill
        end
        host.statuses.size.should eq(total)
      end
    ensure
      Gori::Settings.notify_toast = prev_toast
    end
  end
end
