require "../support/tui_contract"
require "file_utils"

include Gori::Tui

# CONTRACT: a keystroke that changes no bytes marks nothing dirty.
#
# `⌫` at the buffer start, `⌦` at its end, `⌥⌫` with no word behind the caret and `⌃Z` on an
# empty undo stack are all no-ops — `TextArea` returns early without bumping `#edits`. The
# owning view's dirty flag must return early too, and "it's only a flag" is exactly the
# reasoning that made this a four-time regression:
#
#   * Repeater (#936): `mark_req_edit` also sets `@ws_out_edited`, so one `⌃Z` in READ on an
#     untouched WebSocket tab took the pane off its seed and dropped every frame it was not
#     showing — a captured BIN frame vanished between two identical replays.
#   * Intercept (#513): once dirty, `forward_bytes` recomputes Content-Length and normalizes
#     line endings, so a held message the operator only LOOKED at forwarded as different bytes
#     — a P7 violation reached by pressing an idle key.
#   * Notes (#939): `dirty?` is the lock that holds off a peer's reload, so a stray `⌃Z` in a
#     clean note silenced every peer refresh until something else saved.
#   * Fuzzer (#937): `template_undo` on a seeded template re-persisted a template nobody
#     changed.
#
# Each was fixed for the one editor where it was reported. This is the rule stated once, over
# every multi-line editor in the TUI, so the fifth one is caught by a spec rather than by an
# operator noticing bytes they did not type.
#
# Each probe below runs on a FRESHLY built surface, because a dirty flag is one-way: a view
# that dirtied on the first no-op would make every later probe unreadable.
private record EditorSurface,
  name : String,
  dirty : Proc(Bool),
  undo : Proc(Nil),
  backspace : Proc(Nil),
  forward_delete : Proc(Nil)?,
  word_delete : Proc(Nil)?,
  to_buffer_start : Proc(Nil),
  to_buffer_end : Proc(Nil),
  real_edit : Proc(Nil)

private def with_store(name : String, &)
  dir = File.tempname("gori-#{name}")
  Dir.mkdir_p(dir)
  path = File.join(dir, "gori.db")
  store = Gori::Store.open(path)
  begin
    yield store, Gori::Project.new(name, path)
  ensure
    store.close rescue nil
    FileUtils.rm_rf(dir)
  end
end

# Every multi-line editor surface, built clean and in INSERT. Notes and the Project
# description start EMPTY (buffer start and end are the same place, so their positioning
# closures are no-ops); the Fuzzer template and the Repeater request pane are seeded with
# `load_blank`'s scaffold and have to be walked to the right end per probe.
#
# The locals are named per surface rather than reusing one `view`: two unrelated classes bound
# to the same local across `yield`s trips a codegen bug in Crystal 1.21 ("BUG: trying to
# downcast").
private def each_editor_surface(& : EditorSurface ->)
  with_store("notes-noop") do |store, _project|
    nv = NotesView.new
    nv.reload(store)
    nv.enter_insert!
    yield EditorSurface.new("NotesView",
      dirty: -> { nv.dirty? },
      undo: -> { nv.undo },
      backspace: -> { nv.backspace },
      forward_delete: -> { nv.delete },
      word_delete: nil, # ⌥⌫ arrives through `motion_key`, which is already gated on `edits`
      to_buffer_start: -> { },
      to_buffer_end: -> { },
      real_edit: -> { nv.insert('x') })
  end

  with_store("project-noop") do |store, project|
    pv = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
    pv.reload(project, store)
    pv.focus_pane(:desc)
    pv.enter_desc_insert!
    yield EditorSurface.new("ProjectView (description)",
      dirty: -> { pv.@desc_dirty },
      undo: -> { pv.undo },
      backspace: -> { pv.backspace },
      forward_delete: nil, # the description pane wires no forward-delete
      word_delete: nil,    # ⌥⌫ arrives through `desc_motion_key`, already gated on `edits`
      to_buffer_start: -> { },
      to_buffer_end: -> { },
      real_edit: -> { pv.insert('x') })
  end

  fv = FuzzerView.new
  fv.load_blank
  fv.focus_pane(:template)
  fv.enter_template_insert!
  fv.clear_dirty
  yield EditorSurface.new("FuzzerView (template)",
    dirty: -> { fv.dirty? },
    undo: -> { fv.template_undo },
    backspace: -> { fv.template_backspace },
    forward_delete: -> { fv.template_delete },
    word_delete: -> { fv.template_delete_word },
    to_buffer_start: -> { fv.template_buffer_start },
    to_buffer_end: -> { fv.template_buffer_end },
    real_edit: -> { fv.template_insert('x') })

  rv = RepeaterView.new
  rv.load_blank
  rv.focus_pane(:request)
  rv.enter_request_insert!
  rv.clear_dirty
  yield EditorSurface.new("RepeaterView (request)",
    dirty: -> { rv.dirty? },
    undo: -> { rv.edit_undo },
    backspace: -> { rv.edit_backspace },
    forward_delete: -> { rv.edit_delete },
    word_delete: -> { rv.edit_delete_word },
    to_buffer_start: -> { rv.edit_buffer_start },
    to_buffer_end: -> { rv.edit_buffer_end },
    real_edit: -> { rv.edit_insert('x') })
end

describe "TUI editor contract — a no-op keystroke dirties nothing" do
  it "^Z on an empty undo stack" do
    offenders = [] of String
    each_editor_surface do |s|
      s.dirty.call.should be_false # the surface really starts clean, or nothing here means anything
      s.undo.call
      offenders << s.name if s.dirty.call
    end
    offenders.should be_empty
  end

  it "backspace at the buffer start" do
    offenders = [] of String
    each_editor_surface do |s|
      s.to_buffer_start.call
      s.backspace.call
      offenders << s.name if s.dirty.call
    end
    offenders.should be_empty
  end

  it "forward-delete at the buffer end" do
    offenders = [] of String
    each_editor_surface do |s|
      next unless fwd = s.forward_delete
      s.to_buffer_end.call
      fwd.call
      offenders << s.name if s.dirty.call
    end
    offenders.should be_empty
  end

  it "word-delete with no word behind the caret" do
    offenders = [] of String
    each_editor_surface do |s|
      next unless wd = s.word_delete
      s.to_buffer_start.call
      wd.call
      offenders << s.name if s.dirty.call
    end
    offenders.should be_empty
  end

  # The control. Without it every assertion above is satisfied by a view that never dirties,
  # which is the same bug with the sign flipped — and a worse one, since it loses text.
  it "a real edit still dirties" do
    missing = [] of String
    each_editor_surface do |s|
      s.real_edit.call
      missing << s.name unless s.dirty.call
    end
    missing.should be_empty
  end
end

# The Project description's dirty flag is not merely bookkeeping: `ProjectView#reload` refuses
# to re-seed a DIRTY buffer from the store, deliberately, so a peer's write cannot clobber
# prose the operator has not saved yet. That makes an idle `^Z` a silent mute on every later
# refresh of the pane — the same consequence `NotesView`'s guard was added for (#939) — so the
# contract above is stated once more here in the terms the operator would notice it.
describe "ProjectView — an idle key does not mute a peer's description write" do
  it "still adopts the stored value after ^Z and backspace over a clean buffer" do
    with_store("project-peer") do |store, project|
      store.set_setting(ProjectView::DESC_KEY, "written here").should be_true
      view = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
      view.reload(project, store)
      view.focus_pane(:desc)
      view.enter_desc_insert!
      view.desc_text.should eq("written here")

      view.undo      # empty undo stack: nothing to take back
      view.backspace # caret is at the buffer start: nothing behind it

      store.set_setting(ProjectView::DESC_KEY, "written by another window").should be_true
      view.reload(project, store)
      view.desc_text.should eq("written by another window")
    end
  end
end
