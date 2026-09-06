require "../spec_helper"
require "../support/memory_backend"
require "file_utils"

include Gori::Tui

# The Notes tab carves the link preview out of the EDITOR's last row, and nothing checked that
# there was a row to spend. On a short pane `carve_links_row` placed it at `rect.y - 1` — the
# filter bar ABOVE the editor — and handed the editor a negative height, so the two writers
# shared a row and the bar read `/linkser[repeater] XSS PoC (+2)`. Same family as
# `short_pane_clamp_spec`: clamp one axis, forget the other. Every size below is one the app
# renders at (`Layout.usable?` is 40x8).

private class NotesFakeHost
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
    action.call # no modal in a spec: a confirmed action runs straight through
  end

  def overlay : Symbol
    :none
  end

  def active_tab : Symbol
    :notes
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

# The CA is the slow part of standing a Session up and no example asserts anything about it.
private NOTES_CA_ROOT = File.tempname("gori-notes-ca")
Spec.after_suite { FileUtils.rm_rf(NOTES_CA_ROOT) }

private def with_notes_controller(&)
  root = File.tempname("gori-notes")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("notes")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(NOTES_CA_ROOT), Gori::Verbs.registry, project)
  begin
    controller = NotesController.new(NotesFakeHost.new(session))
    # Two notes, so the sub-tab strip and the `/ filter` bar are both on the pane — the two
    # rows the link preview must not land on.
    3.times { controller.notes_new }
    controller.view.link_preview = "[repeater] XSS PoC (+2)"
    yield controller
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def notes_rows(controller : NotesController, w : Int32, h : Int32) : Array(String)
  backend = MemoryBackend.new(w, h)
  controller.render_body(Screen.new(backend), Rect.new(0, 0, w, h), :body)
  (0...h).map { |y| backend.row(y) }
end

describe "Gori::Tui::NotesController — the link preview row" do
  it "never lands on the filter bar above it" do
    with_notes_controller do |controller|
      # `layout.body` on an 80-column terminal is 76 wide; 2..8 rows is what terminals from 8
      # to 14 rows hand this tab, and 8 is the first height the preview has a row of its own.
      (2..8).each do |h|
        rows = notes_rows(controller, 76, h)
        # The preview may be given up entirely — what it may never do is share a row with
        # something else. Whatever row carries it must carry nothing but it.
        row = rows.find(&.includes?("[repeater] XSS PoC (+2)"))
        next unless row                         # (h=#{h}) no room for the preview at all
        row.should_not contain("/ filter")      # (h=#{h}) the bar it used to overwrite
        row.should_not contain("─")             # (h=#{h}) nor the divider under it
        row.should contain("links  [repeater]") # (h=#{h}) label and value, one space apart
      end
    end
  end

  # The other half: the row is only given up when there is no room for it.
  it "still draws the preview once the editor has a row to spare" do
    with_notes_controller do |controller|
      rows = notes_rows(controller, 76, 20)
      rows.any? { |r| r.includes?("links") && r.includes?("[repeater] XSS PoC (+2)") }.should be_true
    end
  end
end

# Bulk paste opt-in (TabController#accepts_bulk_paste?). Notes was the one multi-line editor
# still taking a paste keystroke by keystroke — the Repeater and Fuzzer opted in when the bulk
# path landed — and it is the tab a response body or a whole writeup gets pasted into.
describe "Gori::Tui::NotesController — bracketed paste in bulk" do
  it "takes a paste in bulk only while the note is in INSERT" do
    with_notes_controller do |controller|
      view = controller.view
      view.exit_insert!                              # `notes_new` (the helper's setup) drops into INSERT; start from READ
      controller.accepts_bulk_paste?.should be_false # READ: no caret, and the Runner refuses the paste
      controller.paste_text("x").should be_false
      view.current_text.should eq("")

      view.enter_insert!
      controller.accepts_bulk_paste?.should be_true
      controller.paste_text("line 1\nline 2").should be_true
      view.current_text.should eq("line 1\nline 2")
      view.dirty?.should be_true
    end
  end

  it "says how many characters a paste replaced, like a typed character does" do
    with_notes_controller do |controller|
      view = controller.view
      host = controller.@host.as(NotesFakeHost)
      view.enter_insert!
      "old text".each_char { |c| view.insert(c) }
      view.home
      8.times { view.motion_key(Termisu::Event::Key.new(Termisu::Input::Key::Right, Termisu::Input::Modifier::Shift)) }
      controller.paste_text("new").should be_true
      view.current_text.should eq("new")
      host.statuses.last.should eq("replaced 8 chars — ^Z to undo")
    end
  end
end

# Closing a note drops its `entity_links` — but WHEN depends on whether the note is on disk,
# and the two halves fail in opposite directions.
#
# A PERSISTED note's links wait for `Notes.save` to commit: dropping them on the keypress
# destroyed the operator's evidence against a document that had not been written yet, so a save
# the project's writer then refused left the note on disk with its links already gone.
#
# A note this session minted and never saved is the other half: nothing on disk can bring it
# back, so no later commit ever reaches its links and they would sit in `entity_links` for the
# life of the project. That one is dropped at the close.
describe "Gori::Tui::NotesController — a closed note's links" do
  it "drops them at once for a note that was never persisted" do
    with_notes_controller do |controller|
      controller.notes_new
      id = controller.view.current_note_id
      controller.view.unpersisted?(id).should be_true
      store = controller.@host.as(NotesFakeHost).session.store
      store.add_link(Gori::Store::LinkOwnerKind::Note, id, Gori::Store::LinkRefKind::Flow, 7_i64)

      controller.notes_close

      store.list_links(Gori::Store::LinkOwnerKind::Note, id).should be_empty
    end
  end

  it "leaves a PERSISTED note's links to the save, so a refused write cannot destroy them" do
    with_notes_controller do |controller|
      controller.notes_new
      id = controller.view.current_note_id
      store = controller.@host.as(NotesFakeHost).session.store
      store.add_link(Gori::Store::LinkOwnerKind::Note, id, Gori::Store::LinkRefKind::Flow, 7_i64)
      controller.save_notes.should be_true
      controller.view.unpersisted?(id).should be_false # the commit made it persisted

      controller.notes_close

      # Still there at the close…
      store.list_links(Gori::Store::LinkOwnerKind::Note, id).size.should eq(1)
      # …and gone once the document that removes the note has committed.
      controller.save_notes.should be_true
      store.list_links(Gori::Store::LinkOwnerKind::Note, id).should be_empty
    end
  end
end
