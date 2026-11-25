require "../../spec_helper"
require "../../support/fake_host"
require "../../support/memory_backend"
require "file_utils"

include Gori::Tui

private FUZZ_CTL_CA = File.tempname("gori-fuzz-ctl-ca")
Spec.after_suite { FileUtils.rm_rf(FUZZ_CTL_CA) }

private def with_fuzzer_controller(&)
  root = File.tempname("gori-fuzz-ctl")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("fuzz")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(FUZZ_CTL_CA), Gori::Verbs.registry, project)
  begin
    yield FuzzerController.new(FakeHost.new(session)), session
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def fuzz_result(idx : Int32, shape : Int64 = idx.to_i64) : Gori::Fuzz::Result
  Gori::Fuzz::Result.new(idx.to_i64, ["p#{idx}"], nil, 200, 10_i64 + idx, 3, 1, 1000_i64,
    nil, false, false, nil, shape: shape)
end

# A finished run of `rows` on RESULTS.
private def finished_results(ctl : FuzzerController, rows : Array(Gori::Fuzz::Result)) : FuzzerView
  ctl.fuzz_new
  view = ctl.current_view.not_nil!
  view.load_request("https://h", "GET /?x=1 HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
  view.begin_run(rows.size.to_i64)
  rows.each { |r| view.append_result(r) }
  view.finish_run("done")
  view.focus_pane(:results)
  view
end

private def page_key(k : Termisu::Input::Key) : Termisu::Event::Key
  Termisu::Event::Key.new(k)
end

private PAGE_KEYS = {Termisu::Input::Key::Home, Termisu::Input::Key::End,
                     Termisu::Input::Key::PageUp, Termisu::Input::Key::PageDown}

describe FuzzerController do
  describe "PgUp/PgDn/Home/End over RESULTS (#1443)" do
    it "declines them to the Runner's page route and moves the selection there" do
      with_fuzzer_controller do |ctl|
        view = finished_results(ctl, (0...50).map { |i| fuzz_result(i) })
        view.select_result_row(25)

        PAGE_KEYS.each { |k| ctl.handle_body_key(page_key(k)).should be_false }
        view.results_selected_index.should eq(25) # declined, not acted on

        # The Runner sends Home/End as ±JUMP_ROWS; `results_move` clamps them.
        ctl.body_scroll(-Runner::JUMP_ROWS).should be_true
        view.results_selected_index.should eq(0)
        ctl.body_scroll(Runner::JUMP_ROWS).should be_true
        view.results_selected_index.should eq(49)
      end
    end

    it "pages by the rows RESULTS drew last frame" do
      with_fuzzer_controller do |ctl|
        view = finished_results(ctl, (0...50).map { |i| fuzz_result(i) })
        ctl.page_rows.should eq(1) # nothing drawn yet

        view.render(Screen.new(MemoryBackend.new(120, 40)), Rect.new(0, 0, 120, 40))
        step = ctl.page_rows.not_nil!
        step.should be > 1
        ctl.body_scroll(step).should be_true
        view.results_selected_index.should eq(step)
        ctl.body_scroll(-step).should be_true
        view.results_selected_index.should eq(0)
      end
    end

    # Grouped by shape (#1351) the list is the clusters' lines, so End lands on the last line
    # drawn, never on a member of a folded cluster.
    it "jumps over the grouped lines as drawn" do
      with_fuzzer_controller do |ctl|
        # A ×3 (0,1,2) · B ×2 (3,4) · C ×1 (5): rare first puts C, then B, then A last.
        shapes = [0xa_i64, 0xa_i64, 0xa_i64, 0xb_i64, 0xb_i64, 0xc_i64]
        view = finished_results(ctl, shapes.map_with_index { |s, i| fuzz_result(i, s) })
        ctl.fuzz_toggle_group

        ctl.body_scroll(Runner::JUMP_ROWS).should be_true
        view.results_selected_index.should eq(2)
        view.selected_result.not_nil!.index.should eq(0) # A's header, its members folded

        view.fold_group(true).should be_true # open A: its members follow its header
        ctl.body_scroll(Runner::JUMP_ROWS).should be_true
        view.results_selected_index.should eq(4)
        view.selected_result.not_nil!.index.should eq(2)
        ctl.body_scroll(-Runner::JUMP_ROWS).should be_true
        view.results_selected_index.should eq(0)
      end
    end

    it "leaves the keys to DETAIL, whose read pane owns them" do
      with_fuzzer_controller do |ctl|
        view = finished_results(ctl, (0...50).map { |i| fuzz_result(i) })
        view.open_detail
        view.focus.should eq(:detail)
        ctl.handle_body_key(page_key(Termisu::Input::Key::Home)).should be_true
        ctl.body_scroll(Runner::JUMP_ROWS).should be_false
        ctl.page_rows.should be_nil
      end
    end
  end
end

# ^Q's second press saves and says "chain saved" — but only over a committed save: a refused
# one has already said "NOT saved", and painting success over it hid the lost write.
describe "FuzzerController#fuzz_focus_chain_pane" do
  it "does not claim the chain saved when the store refused the write" do
    with_fuzzer_controller do |ctl|
      host = ctl.@host.as(FakeHost)
      ctl.fuzz_new
      view = ctl.current_view.not_nil!
      view.load_request("https://h", "§x§ HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
      view.focus_pane(:template)
      ctl.fuzz_focus_chain_pane # in a marker → opens the pane
      view.chain_pane_active?.should be_true
      "rot13".each_char { |c| view.handle_chain_pane_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerA, char: c)) }
      host.session.store.@db.exec("CREATE TRIGGER block_fuzz_update BEFORE UPDATE ON fuzz_sessions " \
                                  "BEGIN SELECT RAISE(ABORT, 'blocked'); END")

      ctl.fuzz_focus_chain_pane

      host.statuses.last.should contain("NOT saved")
    end
  end
end

# Esc on the converter list Tab opened closes the list; only the next esc discards the chain.
describe "FuzzerController esc in the CHAIN pane" do
  it "closes an open converter list before it discards the chain" do
    with_fuzzer_controller do |ctl|
      ctl.fuzz_new
      view = ctl.current_view.not_nil!
      view.load_request("https://h", "§x§ HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
      view.focus_pane(:template)
      ctl.fuzz_focus_chain_pane
      "md5".each_char { |c| view.handle_chain_pane_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerA, char: c)) }
      tab = Termisu::Event::Key.new(Termisu::Input::Key::Tab)
      2.times { ctl.handle_editor_tab(tab) } # accept md5, then list every converter
      esc = Termisu::Event::Key.new(Termisu::Input::Key::Escape)
      ctl.handle_body_key(esc)
      view.chain_pane_active?.should be_true
      view.@chain_pane.value.should eq("md5 > ")
      ctl.handle_body_key(esc)
      view.chain_pane_active?.should be_false
    end
  end
end

# The Set and Advanced cards commit to the view they were opened on. Reconcile runs under the
# modal, so a peer closing that session re-anchors `current_view` on a neighbour.
describe "FuzzerController — a card's commit after a peer closed its session" do
  it "does not write a Set edit into the neighbour" do
    with_fuzzer_controller do |ctl, session|
      ctl.fuzz_from_request("https://a.invalid", "GET /a?x=§1§ HTTP/1.1\r\nHost: a\r\n\r\n", false, nil)
      ctl.fuzz_from_request("https://b.invalid", "GET /b?y=§1§ HTTP/1.1\r\nHost: b\r\n\r\n", false, nil)
      ctl.view_at(1).not_nil!.apply_set(nil, SetSpec.new(:list, "b-own\n"))
      ctl.jump_subtab(0)
      ctl.save_all
      a = ctl.view_at(0).not_nil!
      b = ctl.view_at(1).not_nil!
      before = b.set_specs.map(&.value)
      session.store.delete_fuzz_session(ctl.db_id_at(0).not_nil!).should be_true
      ctl.reconcile
      ctl.apply_fuzz_set(a, 0, SetSpec.new(:list, "other\n"))
      b.set_specs.map(&.value).should eq(before)
    end
  end

  it "does not reach a running neighbour's live Config with an Advanced edit" do
    with_fuzzer_controller do |ctl, session|
      ctl.fuzz_from_request("https://a.invalid", "GET /a?x=§1§ HTTP/1.1\r\nHost: a\r\n\r\n", false, nil)
      ctl.fuzz_from_request("https://b.invalid", "GET /b?y=§1§ HTTP/1.1\r\nHost: b\r\n\r\n", false, nil)
      ctl.save_all
      b = ctl.view_at(1).not_nil!
      b.begin_run(nil) # mid-sweep: its Config is shared with the live engine
      ctl.jump_subtab(0)
      a = ctl.view_at(0).not_nil!
      flipped = a.advanced_snapshot.copy_with(follow: !b.config.follow_redirects?)
      session.store.delete_fuzz_session(ctl.db_id_at(0).not_nil!).should be_true
      ctl.reconcile
      before = b.config.follow_redirects?
      ctl.apply_fuzz_advanced(a, flipped)
      b.config.follow_redirects?.should eq(before)
    end
  end

  # ← on CONFIG focuses TEMPLATE and ↵ cycles the mode (`edit_config`, `activate_config_row`).
  it "names the Mode row's real keys" do
    with_fuzzer_controller do |ctl, _session|
      ctl.fuzz_new
      v = ctl.current_view.not_nil!
      v.focus_pane(:config)
      4.times { v.form_move(1) unless v.config_row == :mode }
      v.config_row.should eq(:mode)
      hint = ctl.body_hint(:body)
      hint.should contain("→/↵ next mode · ← template")
      hint.should_not contain("open editor")
    end
  end
end

# At 80x24 the CONFIG footer read `→/↵ next mode · ← template · ↑/↓ row · ^R run · ↹ pane …`:
# with no `cmds` segment for `Chrome.fit_hints` to anchor on, `esc sub-tabs` was cut first.
describe "FuzzerController — CONFIG footer on an 80-column row" do
  it "keeps the menu and the way out on every row" do
    with_fuzzer_controller do |ctl, _session|
      ctl.fuzz_new
      v = ctl.current_view.not_nil!
      v.apply_set(nil, SetSpec.new(:list, "aa")) # so the :set row exists
      v.focus_pane(:config)
      rows = [] of Symbol
      6.times do
        rows << v.config_row
        hint = ctl.body_hint(:body)
        Chrome.fit_hints(hint, 57).should end_with("space cmds · esc sub-tabs"), hint
        v.form_move(1)
      end
      rows.uniq.first(3).should eq([:set, :add, :mode])
      rows.uniq.size.should eq(4) # …and an Advanced row
    end
  end
end

# `space → o sort · m matched · v dist` read as if `m` and `v` were behind `space` too.
describe "FuzzerController — RESULTS footer" do
  it "names the direct keys before the menu paths, and keeps the tail at 80 columns" do
    with_fuzzer_controller do |ctl, _session|
      finished_results(ctl, [fuzz_result(0), fuzz_result(1)])
      hint = ctl.body_hint(:body)
      first_path = hint.index!("space →")
      hint.index!("matched").should be < first_path
      hint.index!("dist").should be < first_path
      hint.index!(" run").should be < first_path
      Chrome.fit_hints(hint, 57).should end_with("space cmds · esc sub-tabs")
    end
  end
end

describe "FuzzerController — an edit made while a run is going" do
  it "toasts once per run that it applies to the next run" do
    with_fuzzer_controller do |ctl|
      host = ctl.@host.as(FakeHost)
      ctl.fuzz_new
      view = ctl.current_view.not_nil!
      view.begin_run(nil)
      ctl.drain_events
      host.statuses.none?(&.includes?("next run")).should be_true
      view.cycle_mode_forward
      ctl.drain_events.should be_true
      view.target_insert('x')
      ctl.drain_events
      host.statuses.count(&.includes?("next run")).should eq(1)
      view.finish_run("done")
      view.begin_run(nil)
      view.cycle_mode_forward
      ctl.drain_events
      host.statuses.count(&.includes?("next run")).should eq(2)
    end
  end
end

# `9 hits / 9 sent` under a success toast, on a run with no match rule: every response passes
# then, so the line reported nine findings for a sweep that judged nothing.
describe "FuzzerController.done_line" do
  run = ->(rule : String?) do
    view = FuzzerView.new
    view.load_request("https://h", "GET /?x=1 HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    view.matcher.match_status = rule
    view.begin_run(2_i64)
    2.times do |i|
      view.append_result(Gori::Fuzz::Result.new(i.to_i64, ["p#{i}"], nil, 200, 1_i64, 1, 1, 1_i64, nil, true, false, nil))
    end
    view.finish_run("done")
    view
  end

  it "names the missing rule, at info level" do
    FuzzerController.done_line(run.call(nil), " on GET /", "")
      .should eq({:info, "Fuzzer: 2 sent on GET / — no match rule"})
  end

  it "counts hits under a rule, as a success when there are any" do
    FuzzerController.done_line(run.call("200"), " on GET / (stopped)", " · macro: 1 failed")
      .should eq({:success, "Fuzzer: 2 hits / 2 sent on GET / (stopped) · macro: 1 failed"})
  end

  # A sweep against a dead port finished as "✓ 200 sent"; the CLI says `200 errors` (W#4).
  failing = ->(errors : Int32, total : Int32) do
    view = FuzzerView.new
    view.load_request("https://h", "GET /?x=1 HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    view.begin_run(total.to_i64)
    total.times do |i|
      err = i < errors ? "connect failed: 127.0.0.1:9 — host unreachable" : nil
      view.append_result(Gori::Fuzz::Result.new(i.to_i64, ["p#{i}"], nil, err ? nil : 200, 1_i64, 1, 1, 1_i64, err, false, false, nil))
    end
    view.finish_run("done")
    view
  end

  it "reports a run where every request failed as an error" do
    FuzzerController.done_line(failing.call(3, 3), " on GET /", "")
      .should eq({:error, "Fuzzer: all 3 failed on GET /"})
  end

  it "counts errors beside the sent count, and warns when most failed" do
    FuzzerController.done_line(failing.call(1, 4), " on GET /", "")
      .should eq({:info, "Fuzzer: 4 sent, 1 error on GET / — no match rule"})
    FuzzerController.done_line(failing.call(3, 4), " on GET /", "")[0].should eq(:warn)
  end
end

describe "FuzzerController — prepared peer tab" do
  it "picks up a tab authored through MCP and builds the same run as a hand-made tab" do
    with_fuzzer_controller do |ctl, session|
      args = JSON.parse({"template" => "GET /?q=§x§ HTTP/1.1\r\nHost: h\r\n\r\n",
                         "url" => "http://h", "payloads" => [{"list" => ["a", "b"]}], "name" => "peer draft"}.to_json)
      tools = Gori::MCP::Tools.new(session.store, allow_actions: true, verify_upstream: false,
        denied_permissions: Set{"send"})
      result = tools.call("create_fuzzer", args)
      result.is_error.should be_false, result.text
      ctl.reconcile
      ctl.count.should eq(1)
      view = ctl.view_at(0).not_nil!
      view.name.should eq("peer draft")
      host = ctl.@host.as(FakeHost)
      host.notifications.latest.not_nil!.message.should eq("Fuzzer tab added: peer draft")
      host.notifications.latest.not_nil!.goto.not_nil!.session_id.should eq(ctl.db_id_at(0))
      prepared, error = view.build_engine(false, session.scope, project: session.store)
      error.should be_nil
      manual = FuzzerView.new
      manual.load_request("http://h", args["template"].as_s, false, "")
      manual.apply_set(nil, SetSpec.list(["a", "b"]))
      handmade, error = manual.build_engine(false, session.scope, project: session.store)
      error.should be_nil
      prepared.not_nil!.total.should eq(handmade.not_nil!.total)
      ctl.stop_all
    end
  end
end

# Records the kind a toast was raised with — FakeHost keeps only the text.
private class KindedFuzzHost < FakeHost
  getter kinded = [] of {String, Symbol}

  def status(message : String, kind : Symbol) : Nil
    @kinded << {message, kind}
    super
  end
end

describe "FuzzerController#fuzz_run refusals" do
  # A plan refusal is a sentence the 59-column toast cuts, and it was a plain toast, so the
  # Notifications card (which keeps `:error` toasts only) never had it either.
  it "raises a plan refusal as an :error toast" do
    with_fuzzer_controller do |_, session|
      host = KindedFuzzHost.new(session)
      ctl = FuzzerController.new(host)
      ctl.fuzz_new
      view = ctl.current_view.not_nil!
      view.load_request("https://h", "GET /?x=1 HTTP/1.1\r\nHost: h\r\n\r\n", false, "") # no marker
      view.apply_set(nil, Gori::Tui::SetSpec.list(["a"]))
      ctl.fuzz_run
      host.kinded.size.should eq(1)
      host.kinded.first[1].should eq(:error)
    end
  end
end

# Records every confirm and holds its action unanswered: the operator pressed esc / cancel
# unless the example runs `pending` itself.
private class DecliningFuzzHost < FakeHost
  getter asked = [] of {String, String, Bool}
  property pending : Proc(Nil)?

  def confirm(title : String, message : String, *, confirm_label : String, danger : Bool,
              return_to : Symbol = :none, &action : -> Nil) : Nil
    @asked << {title, message, danger}
    @pending = action
  end
end

# A finished, never-saved run of `rows` results on a session that can run again. `hits` rows
# match under a real match rule (status 200); with `hits: nil` the run has no rule at all.
private def unsaved_fuzz_run(ctl : FuzzerController, payloads : Array(String), rows : Int32 = 2,
                             hits : Int32? = 1) : FuzzerView
  ctl.fuzz_from_request("http://a.invalid", "GET /?x=§1§ HTTP/1.1\r\nHost: a.invalid\r\n\r\n", false, nil)
  view = ctl.current_view.not_nil!
  view.apply_set(nil, SetSpec.list(payloads))
  view.matcher.match_status = "200" if hits
  view.begin_run(rows.to_i64)
  rows.times do |i|
    hit = !hits.nil? && i < hits
    view.append_result(Gori::Fuzz::Result.new(i.to_i64, ["p#{i}"], nil, hit ? 200 : 404, 10_i64, 3, 1,
      1000_i64, nil, hit, false, nil, shape: i.to_i64))
  end
  view.finish_run("done")
  view
end

# ^R replaced RESULTS and deleted the run's private spool without a word, while loading a saved
# run over the same rows asked first. It asks now, but only over a run that found something,
# and ↵ runs: tweak-and-re-run is the loop, and `^R ↵` must always run.
describe "FuzzerController#fuzz_run over unsaved results" do
  it "pauses on a run with hits, and keeps them when the operator cancels" do
    with_fuzzer_controller do |_, session|
      host = DecliningFuzzHost.new(session)
      ctl = FuzzerController.new(host)
      view = unsaved_fuzz_run(ctl, ["a", "b"])
      view.results_saveable?.should be_true
      ctl.fuzz_run
      host.asked.size.should eq(1)
      title, message, danger = host.asked.first
      title.should eq("REPLACE UNSAVED RESULTS")
      message.should contain("2-row run (1 hit) has not been saved")
      danger.should be_false # ↵ runs
      view.running?.should be_false
      view.result_count.should eq(2)
      view.results_saveable?.should be_true # ⇧E can still keep them

      host.pending.not_nil!.call # …and `run` on the card starts it
      view.running?.should be_true
      ctl.stop_all
    end
  end

  it "re-runs a sweep that found nothing with no card" do
    with_fuzzer_controller do |_, session|
      [0, nil].each do |hits|
        host = DecliningFuzzHost.new(session)
        ctl = FuzzerController.new(host)
        view = unsaved_fuzz_run(ctl, ["a", "b"], hits: hits) # no hit / no match rule at all
        view.results_saveable?.should be_true
        ctl.fuzz_run
        host.asked.should be_empty
        view.running?.should be_true
        ctl.stop_all
      end
    end
  end

  it "folds the question into the large-run card, which ↵ still runs" do
    with_fuzzer_controller do |_, session|
      host = DecliningFuzzHost.new(session)
      ctl = FuzzerController.new(host)
      view = unsaved_fuzz_run(ctl, (1..1001).map(&.to_s))
      ctl.fuzz_run
      host.asked.size.should eq(1)
      title, message, danger = host.asked.first
      title.should eq("RUN FUZZ")
      message.should contain("has not been saved and will be replaced")
      danger.should be_false
      view.running?.should be_false

      quiet = DecliningFuzzHost.new(session)
      ctl2 = FuzzerController.new(quiet)
      unsaved_fuzz_run(ctl2, (1..1001).map(&.to_s), hits: 0)
      ctl2.fuzz_run
      quiet.asked.first[1].should_not contain("has not been saved")
    end
  end

  it "re-runs without asking once the results are saved" do
    with_fuzzer_controller do |_, session|
      host = DecliningFuzzHost.new(session)
      ctl = FuzzerController.new(host)
      view = unsaved_fuzz_run(ctl, ["a", "b"])
      view.finish_results_save(7_i64)
      view.results_saveable?.should be_false
      ctl.fuzz_run
      host.asked.should be_empty
      view.running?.should be_true
      ctl.stop_all
    end
  end

  it "says the same sentence on the history-load card" do
    with_fuzzer_controller do |_, session|
      host = DecliningFuzzHost.new(session)
      ctl = FuzzerController.new(host)
      unsaved_fuzz_run(ctl, ["a", "b"])
      ctl.save_all
      ctl.load_saved_run(1_i64)
      host.asked.first[0].should eq("REPLACE UNSAVED RESULTS")
      host.asked.first[1].should contain("2-row run (1 hit) has not been saved and will be replaced")
    end
  end
end

# The READ half of the TEMPLATE's ⌃Home/⌃End: INS honoured the modifier (`buffer_jump?`), the
# READ arm did not and stopped at the line's edge. See the Repeater REQUEST's twin.
describe "FuzzerController ⌃Home/⌃End on the READ template" do
  it "jumps the buffer and extends the READ selection to its end, ⌥ alike" do
    {Termisu::Input::Modifier::Ctrl, Termisu::Input::Modifier::Alt}.each do |mod|
      with_fuzzer_controller do |ctl|
        ctl.fuzz_new
        v = ctl.current_view.not_nil!
        v.load_request("https://h", "GET /?x=1 HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
        v.focus_pane(:template)
        v.template_insert?.should be_false
        ctl.handle_body_key(page_key(Termisu::Input::Key::Down)).should be_true
        2.times { ctl.handle_body_key(page_key(Termisu::Input::Key::Right)) }
        ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::End, mod | Termisu::Input::Modifier::Shift)).should be_true
        v.template_copy_text.should start_with("st: h\n")

        ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::Home, mod)).should be_true
        ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::End, Termisu::Input::Modifier::Shift))
        v.template_copy_text.should eq("GET /?x=1 HTTP/1.1")
      end
    end
  end
end
