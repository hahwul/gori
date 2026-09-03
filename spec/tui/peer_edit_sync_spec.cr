require "../spec_helper"
require "file_utils"
require "../../src/gori/tui/controllers/issues_controller"
require "../../src/gori/tui/controllers/intercept_controller"

include Gori::Tui

# What a SECOND writer on the same project db does to this window. Two gori instances (or a
# `gori mcp` / `gori run` beside a TUI) share one SQLite file, and the surfaces here each held
# a private copy of something that file owns:
#
#   * an open Issues detail rendered the row it was OPENED with, forever, while the list
#     behind it already showed the peer's edit — `on_external_change` refreshed only the list;
#   * the notes editor wrote its buffer over whatever was in the column, so the last `esc` in
#     either window silently destroyed the other operator's writeup;
#   * `intercept_toggle` flipped a local flag in a VIEW-ONLY window, where the held traffic
#     lives in the other process entirely.
#
# The peer here is the same store handle (the idiom in `spec/tui/authorize_controller_spec.cr`,
# where `peer_add` reaches the row through its own loader): what makes something a peer edit is
# that it lands in the COLUMN without going through this pane, and that is what these write.

private class PeerSyncHost
  include Gori::Tui::Host

  getter statuses = [] of String
  property active_tab : Symbol = :issues

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

  def last_status : String
    @statuses.last? || ""
  end

  def request_overlay(kind : Symbol) : Nil
  end

  def request_focus(pane : Symbol) : Nil
  end

  def focus_body : Nil
  end

  def resolve_subtab_focus : Nil
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

  def open_authorize_identities : Nil
  end

  def reconfigure_sequence : Nil
  end

  def open_scope_rule_editor(edit_id : Int64?, kind : String, match_type : String, pattern : String) : Nil
  end

  def open_custom_rule_editor(rule : Gori::Probe::CustomRule?) : Nil
  end

  def open_rewriter_preset_picker : Nil
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

  def apply_project_protos(spec : String) : String
    ""
  end
end

# The CA is the slow part of standing a Session up and nothing here asserts about it.
private PEER_SYNC_CA_ROOT = File.tempname("gori-peer-sync-ca")
Spec.after_suite { FileUtils.rm_rf(PEER_SYNC_CA_ROOT) }

private def open_peer_session(project : Gori::Project) : Gori::Session
  Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(PEER_SYNC_CA_ROOT), Gori::Verbs.registry, project)
end

# One project, and as many Sessions over it as the example asks for. The FIRST takes the
# per-project capture lock; every one after it is view-only, which is exactly the second-window
# condition the intercept examples need and cannot fake (`capturing_lock_held?` reads the lock).
private def with_sessions(count : Int32, &)
  root = File.tempname("gori-peer-sync")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("peersync")
  sessions = [] of Gori::Session
  begin
    count.times { sessions << open_peer_session(project) }
    yield sessions
  ensure
    sessions.reverse_each(&.close)
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def with_issues_controller(&)
  with_sessions(1) do |sessions|
    session = sessions.first
    host = PeerSyncHost.new(session)
    yield Gori::Tui::IssuesController.new(host), host, session.store
  end
end

# An issue with the detail card open on it, in READ mode.
private def open_issue(ctrl : Gori::Tui::IssuesController, store : Gori::Store,
                       notes : String = "") : Int64
  id = store.insert_issue("reflected param", Gori::Store::Severity::Medium, "acme.test", nil)
  store.update_issue(id, notes: notes).should be_true unless notes.empty?
  ctrl.view.reload(store)
  ctrl.view.open_detail(store).should be_true
  ctrl.view.detail_issue.not_nil!.id.should eq(id)
  id
end

# `set_text` leaves the caret at 0,0, so typed text lands at the FRONT of the seeded notes.
# That is the editor's real behaviour and no example here depends on where the insertion goes —
# only on the buffer having local text the store has not seen.
private def type(ctrl : Gori::Tui::IssuesController, text : String) : Nil
  text.each_char { |c| ctrl.view.notes_insert(c) }
end

describe "an open Issues detail under a peer's edit" do
  it "re-reads the OPEN issue, not just the list behind it" do
    with_issues_controller do |ctrl, _host, store|
      id = open_issue(ctrl, store)
      store.update_issue(id, severity: Gori::Store::Severity::Critical, notes: "peer wrote this")
      ctrl.on_external_change
      ctrl.view.detail_issue.not_nil!.severity.should eq(Gori::Store::Severity::Critical)
      # Nothing local was in flight, so the notes pane takes the peer's text outright.
      ctrl.view.notes_copy_all.should eq("peer wrote this")
    end
  end

  it "survives the issue being DELETED by a peer while the card is open" do
    with_issues_controller do |ctrl, _host, store|
      id = open_issue(ctrl, store)
      store.delete_issues([id])
      ctrl.on_external_change # get_issue → nil; the render path falls back to the list
      ctrl.view.detail_issue.should be_nil
    end
  end

  it "does NOT clobber an in-progress notes buffer" do
    with_issues_controller do |ctrl, host, store|
      open_id = open_issue(ctrl, store, notes: "original")
      ctrl.view.enter_notes_insert!
      type(ctrl, "mine ")
      store.update_issue(open_id, notes: "original + THEIRS")
      ctrl.on_external_change
      # The typed text is still there, the caret and undo stack with it.
      ctrl.view.notes_copy_all.should eq("mine original")
      ctrl.view.notes_insert_mode?.should be_true
      host.last_status.should contain("changed by another session")
    end
  end

  it "announces a peer's notes ONCE, not on every tick" do
    # This tick also fires on this session's OWN captures — `data_version` cannot say whose
    # commit moved it — so an unlatched warning is ~1.3 lines/sec during a live capture.
    with_issues_controller do |ctrl, host, store|
      id = open_issue(ctrl, store, notes: "original")
      ctrl.view.enter_notes_insert!
      type(ctrl, "!")
      store.update_issue(id, notes: "theirs")
      5.times { ctrl.on_external_change }
      host.statuses.count(&.includes?("changed by another session")).should eq(1)
      # A SECOND distinct peer value is a new fact and is announced again.
      store.update_issue(id, notes: "theirs, revised")
      ctrl.on_external_change
      host.statuses.count(&.includes?("changed by another session")).should eq(2)
    end
  end

  it "does not erase unsaved text the NOR/INS chip stepped out of" do
    # The chip (and a click on it) leaves INS WITHOUT saving, so unsaved text outlives the
    # editor. A mode-shaped dirty test would call that buffer clean, and this tick — which
    # re-seeds a not-inserting pane from the row — would then wipe it. Under live capture the
    # tick fires on this session's own captures, so it would happen within the second, with
    # the operator looking at the text as it vanished.
    with_issues_controller do |ctrl, host, store|
      id = open_issue(ctrl, store, notes: "original")
      ctrl.view.enter_notes_insert!
      type(ctrl, "mine ")
      ctrl.view.exit_notes_insert!
      ctrl.view.notes_insert_mode?.should be_false
      ctrl.view.notes_dirty?.should be_true
      store.update_issue(id, notes: "THEIRS")
      3.times { ctrl.on_external_change }
      ctrl.view.notes_copy_all.should eq("mine original")
      host.statuses.count(&.includes?("changed by another session")).should eq(1)
      # And re-entering the editor picks the text back up rather than re-seeding over it.
      ctrl.view.enter_notes_insert!
      ctrl.view.notes_copy_all.should eq("mine original")
      # The refusal still holds on the way out, because the peer's value is still there.
      ctrl.commit
      store.get_issue(id).not_nil!.notes.should eq("THEIRS")
    end
  end

  it "still re-seeds a CLEAN pane the operator merely stepped out of" do
    with_issues_controller do |ctrl, _host, store|
      id = open_issue(ctrl, store, notes: "original")
      ctrl.view.enter_notes_insert!
      ctrl.view.exit_notes_insert! # entered and left without typing
      store.update_issue(id, notes: "THEIRS")
      ctrl.on_external_change
      ctrl.view.notes_copy_all.should eq("THEIRS")
      ctrl.view.notes_dirty?.should be_false
    end
  end

  it "does not let a LOCAL re-read eat the one announcement it owes" do
    # `severity_delta`/`status_delta`/`save_notes` all call `refresh_detail` after their own
    # write and ignore the verdict. The latch is per-VALUE, so if one of them armed it the
    # announcement would not be delayed — it would never be printed at all. Reachable in INS
    # via the palette, which INS defers every ctrl chord to.
    with_issues_controller do |ctrl, host, store|
      id = open_issue(ctrl, store, notes: "original")
      ctrl.view.enter_notes_insert!
      type(ctrl, "mine ")
      store.update_issue(id, notes: "THEIRS")
      ctrl.view.severity_delta(1, store).should be_true # a local re-read, no verdict wanted
      ctrl.on_external_change
      host.statuses.count(&.includes?("changed by another session")).should eq(1)
    end
  end

  it "says nothing when the tick fires with no peer edit at all" do
    with_issues_controller do |ctrl, host, store|
      open_issue(ctrl, store, notes: "original")
      ctrl.view.enter_notes_insert!
      type(ctrl, "!")
      3.times { ctrl.on_external_change }
      host.statuses.should be_empty
    end
  end
end

describe "the Issues notes lost-update refusal" do
  it "refuses on the `esc` key, which is the save the operator actually presses" do
    # `commit` (tab switch / quit) is speced below; this is the same guard reached through
    # `handle_detail_key`, the only path a keyboard takes. `esc` out of INS is documented as
    # "save", so it is where a lost update would have happened.
    with_issues_controller do |ctrl, host, store|
      id = open_issue(ctrl, store, notes: "original")
      ctrl.view.enter_notes_insert!
      type(ctrl, "mine ")
      store.update_issue(id, notes: "THEIRS")
      ctrl.handle_detail_key(Termisu::Event::Key.new(Termisu::Input::Key::Escape)).should be_true
      store.get_issue(id).not_nil!.notes.should eq("THEIRS")
      host.last_status.should contain("another session rewrote them")
      ctrl.view.notes_insert_mode?.should be_true
    end
  end

  it "refuses to write this window's buffer over a peer's rewrite" do
    with_issues_controller do |ctrl, host, store|
      id = open_issue(ctrl, store, notes: "original")
      ctrl.view.enter_notes_insert!
      type(ctrl, "mine ")
      store.update_issue(id, notes: "THEIRS")
      ctrl.commit # the tab-switch / quit flush takes the same refusal
      store.get_issue(id).not_nil!.notes.should eq("THEIRS")
      host.last_status.should contain("another session rewrote them")
      # Still in INS with the text on screen — the only copy of it that exists.
      ctrl.view.notes_insert_mode?.should be_true
      ctrl.view.notes_copy_all.should eq("mine original")
    end
  end

  it "saves normally when the peer touched a DIFFERENT field" do
    # The guard compares the notes column alone. A peer re-triaging severity while this window
    # types must not strand the writeup — that would make the refusal fire on ordinary use.
    with_issues_controller do |ctrl, host, store|
      id = open_issue(ctrl, store, notes: "original")
      ctrl.view.enter_notes_insert!
      type(ctrl, "mine ")
      store.update_issue(id, severity: Gori::Store::Severity::Critical)
      ctrl.commit
      store.get_issue(id).not_nil!.notes.should eq("mine original")
      host.statuses.should be_empty
    end
  end

  it "saves normally when the peer wrote the SAME text this window was seeded with" do
    # A no-op rewrite (an MCP `update_issue` re-posting what was already there) is not a
    # divergence, and refusing on it would be a false alarm the operator cannot clear.
    with_issues_controller do |ctrl, _host, store|
      id = open_issue(ctrl, store, notes: "original")
      ctrl.view.enter_notes_insert!
      type(ctrl, "X")
      store.update_issue(id, notes: "original")
      ctrl.commit
      store.get_issue(id).not_nil!.notes.should eq("Xoriginal")
    end
  end

  it "lets ^W hand the pane back to the peer's text, and re-arms the save" do
    # The refusal has to have an exit. Discarding re-seeds the baseline from the row that is
    # actually there, so the next edit is measured against the peer's version.
    with_issues_controller do |ctrl, host, store|
      id = open_issue(ctrl, store, notes: "original")
      ctrl.view.enter_notes_insert!
      type(ctrl, "mine ")
      store.update_issue(id, notes: "THEIRS")
      ctrl.view.notes_conflict?(store).should be_true
      ctrl.on_external_change # the tick re-reads the row while INS is open
      ctrl.view.cancel_notes_edit
      ctrl.view.notes_copy_all.should eq("THEIRS")
      ctrl.view.enter_notes_insert!
      type(ctrl, "mine ")
      ctrl.view.notes_conflict?(store).should be_false
      ctrl.commit
      store.get_issue(id).not_nil!.notes.should eq("mine THEIRS")
      # The tick's announce above is expected; what must NOT be here is a second refusal.
      host.statuses.none?(&.includes?("rewrote them")).should be_true
    end
  end

  it "does not fire on a CRLF-stored writeup nobody has touched" do
    # An older TUI wrote `issues.notes` with CRLF (see `IssuesView#save_notes`), while the
    # editor hands its text back LF-joined. Comparing the raw column against the buffer would
    # read every such issue as "a peer changed this" on the first keystroke.
    with_issues_controller do |ctrl, _host, store|
      id = open_issue(ctrl, store, notes: "line one\r\nline two")
      ctrl.view.enter_notes_insert!
      type(ctrl, "!")
      ctrl.view.notes_conflict?(store).should be_false
      ctrl.commit
      store.get_issue(id).not_nil!.notes.should eq("!line one\nline two")
    end
  end

  it "is not raised by an unsaved buffer alone" do
    with_issues_controller do |ctrl, store_host, store|
      id = open_issue(ctrl, store, notes: "original")
      ctrl.view.enter_notes_insert!
      ctrl.view.notes_conflict?(store).should be_false # nothing typed yet
      type(ctrl, "mine ")
      ctrl.view.notes_conflict?(store).should be_false # typed, but the column has not moved
      ctrl.commit
      store.get_issue(id).not_nil!.notes.should eq("mine original")
      store_host.statuses.should be_empty
    end
  end
end

# A guard on this pane can only ever be an interruption. The operator is the one who knows
# whether their paragraph or the peer's is the one worth keeping, and the first cut of this
# refusal gave them no way to say so: `esc` refused forever, `^W` took the peer's text, a tab
# switch refused again, and quitting dropped the buffer with a status line nobody could read
# because the process was already tearing down. Every door out of the room lost the writeup.
describe "the Issues notes refusal, once the operator has read it" do
  it "lets a second `esc` write, and the text that lands is the operator's" do
    with_issues_controller do |ctrl, host, store|
      id = open_issue(ctrl, store, notes: "original")
      ctrl.view.enter_notes_insert!
      type(ctrl, "mine ")
      store.update_issue(id, notes: "THEIRS")
      esc = -> { ctrl.handle_detail_key(Termisu::Event::Key.new(Termisu::Input::Key::Escape)) }
      esc.call
      store.get_issue(id).not_nil!.notes.should eq("THEIRS") # first esc refuses, as before
      host.last_status.should contain("esc again overwrites theirs")
      esc.call
      store.get_issue(id).not_nil!.notes.should eq("mine original")
      ctrl.view.notes_insert_mode?.should be_false # a real save, so INS closes
    end
  end

  it "will not carry an arm across a peer's SECOND write" do
    # The arm is granted against a version the operator was shown. A peer writing again between
    # the two presses means the text on the other side is one nobody has seen, so the second
    # `esc` has to refuse afresh rather than spend an arm earned for different bytes.
    with_issues_controller do |ctrl, host, store|
      id = open_issue(ctrl, store, notes: "original")
      ctrl.view.enter_notes_insert!
      type(ctrl, "mine ")
      store.update_issue(id, notes: "THEIRS")
      esc = -> { ctrl.handle_detail_key(Termisu::Event::Key.new(Termisu::Input::Key::Escape)) }
      esc.call # armed against "THEIRS"
      store.update_issue(id, notes: "THEIRS, REVISED")
      esc.call
      store.get_issue(id).not_nil!.notes.should eq("THEIRS, REVISED") # refused again
      host.statuses.count(&.includes?("esc again overwrites theirs")).should eq(2)
      esc.call # now armed against what is really there
      store.get_issue(id).not_nil!.notes.should eq("mine original")
    end
  end

  it "cannot be pre-armed by an esc that had nothing to refuse" do
    # An ordinary save leaves no arm behind, so a later conflict gets its refusal rather than
    # being spent by a keypress from before it existed.
    with_issues_controller do |ctrl, host, store|
      id = open_issue(ctrl, store, notes: "original")
      ctrl.view.enter_notes_insert!
      type(ctrl, "one ")
      esc = -> { ctrl.handle_detail_key(Termisu::Event::Key.new(Termisu::Input::Key::Escape)) }
      esc.call # a clean save; nothing to arm against
      store.get_issue(id).not_nil!.notes.should eq("one original")
      ctrl.view.enter_notes_insert!
      type(ctrl, "two ")
      store.update_issue(id, notes: "THEIRS")
      esc.call
      store.get_issue(id).not_nil!.notes.should eq("THEIRS") # refused, not silently overwritten
      host.last_status.should contain("esc again overwrites theirs")
    end
  end

  it "drops the arm when ^W answers the refusal instead" do
    # `^W` is the other answer. Leaving the arm behind would make the NEXT conflict on this
    # issue skip its refusal and write over a peer with no warning at all.
    with_issues_controller do |ctrl, host, store|
      id = open_issue(ctrl, store, notes: "original")
      ctrl.view.enter_notes_insert!
      type(ctrl, "mine ")
      store.update_issue(id, notes: "THEIRS")
      ctrl.handle_detail_key(Termisu::Event::Key.new(Termisu::Input::Key::Escape)) # arm
      ctrl.on_external_change                                                      # the tick, so `^W` restores the row as it now stands
      ctrl.handle_detail_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerW, Termisu::Input::Modifier::Ctrl))
      ctrl.view.notes_copy_all.should eq("THEIRS")
      # A fresh edit that collides again must be refused, not written.
      ctrl.view.enter_notes_insert!
      type(ctrl, "second ")
      store.update_issue(id, notes: "THEIRS AGAIN")
      ctrl.handle_detail_key(Termisu::Event::Key.new(Termisu::Input::Key::Escape))
      store.get_issue(id).not_nil!.notes.should eq("THEIRS AGAIN")
      host.statuses.count(&.includes?("esc again overwrites theirs")).should eq(2)
    end
  end

  it "points a refused tab switch at the key that resolves it" do
    with_issues_controller do |ctrl, host, store|
      id = open_issue(ctrl, store, notes: "original")
      ctrl.view.enter_notes_insert!
      type(ctrl, "mine ")
      store.update_issue(id, notes: "THEIRS")
      ctrl.commit
      host.last_status.should contain("esc in the notes pane overwrites theirs")
      # And a tab switch does NOT become a save by being repeated — only `esc` is the save key.
      ctrl.commit
      store.get_issue(id).not_nil!.notes.should eq("THEIRS")
    end
  end

  it "reports the conflict to the exit prompts, which is where quitting can still be undone" do
    with_issues_controller do |ctrl, _host, store|
      id = open_issue(ctrl, store, notes: "original")
      ctrl.notes_conflict_pending?.should be_false
      ctrl.view.enter_notes_insert!
      type(ctrl, "mine ")
      ctrl.notes_conflict_pending?.should be_false # typed, but nobody else has written
      store.update_issue(id, notes: "THEIRS")
      ctrl.notes_conflict_pending?.should be_true
    end
  end

  it "does not blame a peer for a buffer the INS gate drops anyway" do
    # `commit` only saves while the pane is in INS, so a buffer the NOR/INS chip stepped out of
    # is dropped at quit whether or not anybody else wrote — by that gate, not by this conflict.
    # A prompt saying "another session rewrote them" over it would send the operator hunting a
    # collision that is not the reason they lost the text.
    with_issues_controller do |ctrl, _host, store|
      id = open_issue(ctrl, store, notes: "original")
      ctrl.view.enter_notes_insert!
      type(ctrl, "mine ")
      ctrl.view.exit_notes_insert!
      store.update_issue(id, notes: "THEIRS")
      ctrl.view.notes_dirty?.should be_true # there IS unsaved text
      ctrl.notes_conflict_pending?.should be_false
    end
  end
end

# `commit_pending_edits` runs INSIDE the accept block of both exit paths and is followed by the
# loop breaking, so a status line posted from it is never rendered. The confirm is the last
# moment the operator can still choose, so that is where the fact has to be.
describe "the exit prompts when an Issues writeup is in conflict" do
  it "names it in the leave-project confirm" do
    plain = Gori::Tui::Runner.leave_confirm_message(nil, 0)
    plain.should_not contain("writeup")
    warned = Gori::Tui::Runner.leave_confirm_message(nil, 0, true)
    warned.should contain("DISCARDS yours")
    warned.should contain("esc in the notes pane")
  end

  it "names it in the quit confirm, and stops promising the edits are committed" do
    # The parenthetical was the specific lie: it told the operator their pending edits were
    # safe on the one path where one of them was about to be dropped.
    Gori::Tui::Runner.quit_confirm_message(nil, 0).should contain("pending edits are committed")
    warned = Gori::Tui::Runner.quit_confirm_message(nil, 0, true)
    warned.should_not contain("pending edits are committed")
    warned.should contain("DISCARDS yours")
  end

  it "names it in the double-press arm, ahead of the jobs clause" do
    # The ^C/^D arm never raises a modal, so this hint is the whole warning on that path — and
    # it outranks the jobs sentence because a stopped job can be restarted and a writeup cannot
    # be retyped.
    Gori::Tui::Runner.quit_arm_hint(nil, 0).should_not contain("writeup")
    hint = Gori::Tui::Runner.quit_arm_hint("fuzz: acme", 1, notes_conflict: true)
    hint.should contain("DISCARDS yours")
    hint.should contain("press ^D")
  end

  it "keeps both clauses when jobs are running too" do
    msg = Gori::Tui::Runner.quit_confirm_message("fuzz: acme", 1, true)
    msg.should contain("1 job still running")
    msg.should contain("DISCARDS yours")
  end
end

describe "the ui-state row a second window must not clobber" do
  it "is gated, and the bookkeeping is inside the gate" do
    # One `ui_state` row per project, two live instances writing it: `get_current_context`
    # answered from whichever window last moved a cursor, so an agent asking what the operator
    # was looking at got a window they were not in.
    #
    # Source-pinned like the reloads in `spec/tui/session_slots_spec.cr` — `Runner.new` appears
    # nowhere under spec/ (it owns a terminal), and the write only exists on the tick. The
    # DECISION the gate makes is a real example below; this pins that the gate is on the write
    # at all, which no unit test of a pure function can say.
    src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner.cr"))
    body = src.lines.reject(&.lstrip.starts_with?('#')).join('\n')
    write = body[/^ *ident = ui_state_identity.*?\n *end\n/m]
    write.should_not be_nil
    write.not_nil!.should contain("may_publish_ui_state?")
    # The bookkeeping is INSIDE the gate: advancing the throttle/identity while refusing to
    # write would leave a window that later takes capture with `c` silently unpublished until
    # its identity happened to move again.
    guard = write.not_nil!.index("may_publish_ui_state?").not_nil!
    write.not_nil!.index("last_ui_ident =").not_nil!.should be > guard
    write.not_nil!.index("set_setting(Store::UI_STATE_KEY").not_nil!.should be > guard
  end

  # The capture holder always publishes (`may_publish_ui_state?` returns before touching the
  # store), so every example here is the VIEW-ONLY window deciding whether to take the row.
  describe "a view-only window" do
    now = 1_800_000_000_000_i64
    holder = ->(age_ms : Int64) {
      %({"active_tab":"history","holds_capture":true,"recorded_at":#{now - age_ms}})
    }

    it "publishes when there is no row at all — the headless-capture deployment" do
      # `gori run capture` takes the capture lock and draws nothing. Gating on the lock alone
      # meant nobody wrote this row, and `get_current_context` told the agent the TUI "may not
      # have run against it" while the operator was looking at it.
      Gori::Tui::Runner.view_only_may_publish?(nil, now).should be_true
    end

    it "leaves a live holder's row alone — the two-TUI case the gate exists for" do
      Gori::Tui::Runner.view_only_may_publish?(holder.call(5_000_i64), now).should be_false
    end

    it "takes over a holder's row once it has gone a full minute without moving" do
      # Bounded ping-pong, not a fight: both windows write only when their OWN identity moves,
      # so two idle windows never trade the row, and the holder's write is unconditional — any
      # activity there reclaims it on the next tick.
      Gori::Tui::Runner.view_only_may_publish?(holder.call(61_000_i64), now).should be_true
    end

    it "takes a row another view-only window wrote, without waiting a minute" do
      raw = %({"active_tab":"history","holds_capture":false,"recorded_at":#{now - 100_i64}})
      Gori::Tui::Runner.view_only_may_publish?(raw, now).should be_true
    end

    it "takes a row written before the field existed, rather than reading it as a holder's" do
      raw = %({"active_tab":"history","recorded_at":#{now - 100_i64}})
      Gori::Tui::Runner.view_only_may_publish?(raw, now).should be_true
    end

    it "publishes rather than staying silent when the row cannot be read" do
      # The failure this whole gate exists to stop is "nobody publishes", so an unreadable row
      # errs toward writing — the same direction `get_current_context` takes when it cannot
      # parse one.
      Gori::Tui::Runner.view_only_may_publish?("not json", now).should be_true
      Gori::Tui::Runner.view_only_may_publish?("[1,2,3]", now).should be_true
      Gori::Tui::Runner.view_only_may_publish?(%({"holds_capture":true}), now).should be_true
    end
  end
end

describe "intercept in a VIEW-ONLY window" do
  it "refuses the toggle, because the held traffic is in the other process" do
    with_sessions(2) do |sessions|
      capturer, viewer = sessions
      capturer.capturing_lock_held?.should be_true
      viewer.capturing_lock_held?.should be_false

      host = PeerSyncHost.new(viewer)
      ctrl = Gori::Tui::InterceptController.new(host)
      ctrl.intercept_toggle
      # The flag it would have flipped gates the OTHER session's proxy; this one holds nothing.
      viewer.interceptor.enabled?.should be_false
      host.last_status.should contain("view-only")
    end
  end

  it "still toggles in the window that holds capture" do
    with_sessions(1) do |sessions|
      session = sessions.first
      host = PeerSyncHost.new(session)
      ctrl = Gori::Tui::InterceptController.new(host)
      ctrl.intercept_toggle
      session.interceptor.enabled?.should be_true
      host.last_status.should contain("intercept ON")
    end
  end
end

# The quit POLICY, which decides whether an exit prompt is shown at all. Adding the conflict to
# the prompts is worth nothing on the path that shows no prompt.
describe "Runner.quit_decision with an Issues writeup in conflict" do
  it "asks on the palette quit, which otherwise tears down having shown nothing" do
    # `chord: false` is the palette's "Quit gori" verb: it can never arm, so with the confirm
    # setting off it goes straight to `finish_quit` — the one quit that would drop the writeup
    # with no modal, no hint and a status line that is never rendered.
    Gori::Tui::Runner.quit_decision(false, chord: false, armed: false).quit?.should be_true
    Gori::Tui::Runner.quit_decision(false, chord: false, armed: false,
      notes_conflict: true).confirm?.should be_true
  end

  it "leaves the chord's arm alone, because the hint is already the warning" do
    # First ^C/^D still arms (and `quit_arm_hint` names the conflict); the second press is the
    # operator answering it, so re-confirming there would be asking twice for one decision.
    Gori::Tui::Runner.quit_decision(false, chord: true, armed: false,
      notes_conflict: true).arm?.should be_true
    Gori::Tui::Runner.quit_decision(false, chord: true, armed: true,
      notes_conflict: true).quit?.should be_true
  end

  it "changes nothing when the confirm setting is already on" do
    Gori::Tui::Runner.quit_decision(true, chord: false, armed: false).confirm?.should be_true
    Gori::Tui::Runner.quit_decision(true, chord: false, armed: false,
      notes_conflict: true).confirm?.should be_true
  end

  it "changes nothing at all without a conflict" do
    # The default must be byte-for-byte the policy that shipped: this is a quit path, and a
    # regression here is an operator who cannot leave.
    {true, false}.each do |setting|
      {true, false}.each do |chord|
        {true, false}.each do |armed|
          Gori::Tui::Runner.quit_decision(setting, chord: chord, armed: armed)
            .should eq(Gori::Tui::Runner.quit_decision(setting, chord: chord, armed: armed,
              notes_conflict: false))
        end
      end
    end
  end
end
