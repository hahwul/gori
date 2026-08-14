require "../spec_helper"
require "../support/memory_backend"
require "file_utils"

include Gori::Tui

# The Project tab's ENV pane — the per-project `$KEY` table.
#
# It is the only pane on that tab holding its OWN copy of the data it edits (SCOPE and HOST
# OVERRIDES render straight out of one live object), and `Gori::Env.save_project` persists that copy
# WHOLESALE. Three of the four regressions below follow from those two facts together:
#
#   * a peer process's change never reached the copy, so the next commit here wrote the stale
#     set back and deleted the peer's vars;
#   * a rolled-back write said "saved" anyway, and nothing on this surface re-reads the store,
#     so the row went on showing a value that never landed;
#   * an open EDIT row named its target by INDEX into a list that could shrink underneath it.
#
# The fourth is the add-row's ⌫, which asked about the CARET instead of the ROW.

private def tmp_store(&)
  path = File.tempname("gori-env-pane", ".db")
  store = Gori::Store.open(path)
  begin
    yield store, Gori::Project.new("p", path)
  ensure
    store.close rescue nil
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# `Settings.project_env_vars` is a process-wide singleton the whole suite shares — snapshot it
# (and the prefix, which `Env.expand` reads) and always put it back.
private def with_project_vars(vars : Array({String, String}), &)
  saved = Gori::Settings.project_env_vars
  saved_prefix = Gori::Settings.env_prefix
  Gori::Settings.project_env_vars = vars
  Gori::Settings.env_prefix = "$"
  begin
    yield
  ensure
    Gori::Settings.project_env_vars = saved
    Gori::Settings.env_prefix = saved_prefix
  end
end

private def env_view(store : Gori::Store, project : Gori::Project) : ProjectView
  view = ProjectView.new(Gori::Scope.load(store), Gori::HostOverrides.load(store))
  view.reload(project, store)
  view.focus_pane(:env)
  view
end

private def type(view : ProjectView, text : String) : Nil
  text.each_char { |c| view.env_input(c) }
end

# The screen row a var's KEY is drawn on, so a hit-test can be asserted against the DRAW rather
# than against a hand-computed offset that would drift with the card geometry.
private def row_of(view : ProjectView, rect : Rect, needle : String) : Int32
  b = MemoryBackend.new(rect.w, rect.h)
  view.render(Screen.new(b), rect, focused: true)
  (0...rect.h).find { |r| b.row(r).includes?(needle) } || raise "#{needle.inspect} was not drawn"
end

describe "Gori::Env.load_project" do
  # Both repeat callers ask on a cadence (`apply_external_change` on every `data_version` move,
  # which own captures cause; MCP before every outbound tool), and the rev they would bump is
  # what `TextArea`'s styled buffer and `Rules#subst_snapshot` cache against.
  it "publishes, and invalidates, only on a real delta" do
    tmp_store do |store, _project|
      with_project_vars([] of {String, String}) do
        Gori::Env.save_project(store, [{"ALPHA", "1"}]).should be_true
        store.flush
        Gori::Env.load_project(store)
        rev = Gori::Env.highlight_rev

        Gori::Env.load_project(store) # same table, twice more
        Gori::Env.load_project(store)
        Gori::Env.highlight_rev.should eq(rev)
        Gori::Settings.project_env_vars.should eq([{"ALPHA", "1"}])

        store.set_setting(Gori::Env::PROJECT_VARS_KEY,
          Gori::Env.serialize_vars([{"ALPHA", "2"}])).should be_true
        store.flush
        Gori::Env.load_project(store)
        Gori::Env.highlight_rev.should_not eq(rev) # a real change still invalidates
        Gori::Settings.project_env_vars.should eq([{"ALPHA", "2"}])
      end
    end
  end
end

describe "ProjectView ENV pane" do
  it "picks the row under the pointer while the prefix editor holds the first line" do
    tmp_store do |store, project|
      with_project_vars([{"ALPHA", "1"}, {"BETA", "2"}, {"GAMMA", "3"}]) do
        view = env_view(store, project)
        rect = Rect.new(0, 0, 120, 30)

        # Baseline: no sub-mode, the list starts on the first interior line.
        view.env_row_at(rect, 5, row_of(view, rect, "BETA")).should eq(1)

        # The add row takes that line, and the hit-test has always known about it.
        view.env_add_start
        view.env_row_at(rect, 5, row_of(view, rect, "BETA")).should eq(1)
        view.cancel_env_add

        # …and so does the PREFIX row, which the draw offsets identically and the hit-test
        # used to ignore — every click landed one row further down the list than the pointer.
        view.env_prefix_edit_start
        view.env_row_at(rect, 5, row_of(view, rect, "BETA")).should eq(1)
        view.env_row_at(rect, 5, row_of(view, rect, "ALPHA")).should eq(0)
      end
    end
  end

  it "keeps a typed line when ⌫ arrives with the caret at the start" do
    tmp_store do |store, project|
      with_project_vars([] of {String, String}) do
        view = env_view(store, project)
        view.env_add_start
        type(view, "TOKEN abc123")
        view.env_move_cursor(-99) # ← to the head of the line

        # True ⇒ "the row still has text", which is what stops the caller closing it. The old
        # answer was about the CARET, so this ⌫ threw the whole line away.
        view.env_backspace.should be_true
        view.env_commit.should eq(:ok)
        view.env_vars.should eq([{"TOKEN", "abc123"}])
      end
    end
  end

  it "closes the row only once it is genuinely empty" do
    tmp_store do |store, project|
      with_project_vars([] of {String, String}) do
        view = env_view(store, project)
        view.env_add_start
        type(view, "ab")
        view.env_backspace.should be_true
        view.env_backspace.should be_true
        view.env_backspace.should be_false # nothing left ⇒ the caller closes the row
      end
    end
  end

  it "adopts a peer's vars instead of writing a stale list back over them" do
    tmp_store do |store, project|
      with_project_vars([{"ALPHA", "1"}]) do
        view = env_view(store, project)
        view.env_vars.should eq([{"ALPHA", "1"}])

        # A peer process added one and `Runner#apply_external_change` reloaded the global.
        Gori::Settings.project_env_vars = [{"ALPHA", "1"}, {"PEER", "9"}]
        view.reload_env_vars

        # The pane's own copy is what `Gori::Env.save_project` persists wholesale, so this IS the
        # clobber test: adding a var here must not take the peer's with it.
        view.env_add_start
        type(view, "MINE 7")
        view.env_commit.should eq(:ok)
        Gori::Env.save_project(store, view.env_vars).should be_true
        store.flush
        Gori::Env.parse_vars_json(store.setting(Gori::Env::PROJECT_VARS_KEY))
          .should eq([{"ALPHA", "1"}, {"PEER", "9"}, {"MINE", "7"}])
      end
    end
  end

  it "re-anchors an open edit row by KEY when the peer reordered the list" do
    tmp_store do |store, project|
      with_project_vars([{"ALPHA", "1"}]) do
        view = env_view(store, project)
        view.env_edit_start # edits ALPHA, at index 0
        view.cancel_env_add
        view.env_edit_start
        type(view, "9") # "ALPHA 19" — the row is still ALPHA

        Gori::Settings.project_env_vars = [{"PEER", "0"}, {"ALPHA", "1"}]
        view.reload_env_vars # ALPHA is index 1 now

        view.env_commit.should eq(:ok)
        # The edit landed on ALPHA. Against the index alone it hit PEER's slot — or, once the
        # duplicate check saw ALPHA elsewhere, refused the operator's edit as a dup.
        view.env_vars.should eq([{"PEER", "0"}, {"ALPHA", "19"}])
      end
    end
  end

  # `reload` is the OTHER re-seed site. Nothing on the top-level tab-switch path cancels an open
  # ENV row — `flush_active_tab_edits` → `ProjectController#commit` saves the description and
  # the network fields, and `cancel_env_add` lives in `settle_subtab`, which only sub-tab
  # changes reach. So a Project → History → Project round trip past a peer's write hands the
  # open row a list that has shifted under its index.
  it "re-anchors an open edit row across a tab-entry reload too" do
    tmp_store do |store, project|
      with_project_vars([{"ALPHA", "1"}]) do
        view = env_view(store, project)
        view.env_edit_start
        type(view, "9") # "ALPHA 19", still open

        Gori::Settings.project_env_vars = [{"PEER", "0"}, {"ALPHA", "1"}]
        view.reload(project, store) # ← tab entry, not the external-change path

        view.env_commit.should eq(:ok)
        # In range but stale, the index wrote PEER's slot and `Env.save_project` then persisted
        # the whole array — the peer's var deleted by the very commit that added the refresh.
        view.env_vars.should eq([{"PEER", "0"}, {"ALPHA", "19"}])
      end
    end
  end

  it "turns an edit row whose var the peer deleted into an add" do
    tmp_store do |store, project|
      with_project_vars([{"ALPHA", "1"}]) do
        view = env_view(store, project)
        view.env_edit_start

        Gori::Settings.project_env_vars = [] of {String, String}
        view.reload_env_vars # the row this edit indexed into is gone

        # `@env_items[idx] = …` on the emptied list would have raised IndexError out of a
        # keystroke; the typed text is re-added instead.
        view.env_commit.should eq(:ok)
        view.env_vars.should eq([{"ALPHA", "1"}])
      end
    end
  end
end

# --- the controller half: what the operator is TOLD, and what a ⌫ does to their line ---------
#
# `Gori::Env.save_project` answers whether the write committed. A CLOSED store is the honest seam for
# "it did not" — `exec_task_ok` catches Channel::ClosedError and answers false, the same false a
# rolled-back batch produces (see project_desc_persist_spec, which uses it for the same reason).

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

  # The delete path is behind a confirm; run the action, which is what pressing "delete" does.
  def confirm(title : String, message : String, *, confirm_label : String, danger : Bool,
              return_to : Symbol = :none, &action : -> Nil) : Nil
    action.call
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

  def overlay : Symbol
    :none
  end

  def active_tab : Symbol
    :project
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

private ENV_PANE_CA_ROOT = File.tempname("gori-env-pane-ca")
Spec.after_suite { FileUtils.rm_rf(ENV_PANE_CA_ROOT) }

private def with_env_controller(&)
  root = File.tempname("gori-env-pane-session")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("envpane")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(ENV_PANE_CA_ROOT), Gori::Verbs.registry, project)
  saved = Gori::Settings.project_env_vars
  saved_prefix = Gori::Settings.env_prefix
  Gori::Settings.env_prefix = "$"
  begin
    host = FakeHost.new(session)
    c = ProjectController.new(host)
    c.view.focus_pane(:env)
    yield c, host, session
  ensure
    session.close rescue nil
    FileUtils.rm_rf(root) if Dir.exists?(root)
    Gori::Settings.project_env_vars = saved
    Gori::Settings.env_prefix = saved_prefix
  end
end

private def key(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

private def type_keys(c : ProjectController, text : String) : Nil
  text.each_char { |ch| c.handle_body_key(key(Termisu::Input::Key::Unknown, ch)) }
end

describe Gori::Tui::ProjectController do
  it "says a rolled-back env write did NOT save, instead of reporting success" do
    with_env_controller do |c, host, session|
      c.env_add_var
      type_keys(c, "TOKEN sekrit")
      session.store.close # every write from here answers false
      c.handle_body_key(key(Termisu::Input::Key::Enter))

      # The row keeps showing the value (nothing here re-reads the store), so a false "saved"
      # was never contradicted — the var was simply gone at the next launch.
      host.statuses.last.should contain("NOT saved")
      host.statuses.last.should_not contain("env var saved")

      # …and the pane + the substitution table agree with the store, which is what the message
      # claims. `Env.save_project` publishes to the global whatever the store answered, and a
      # rolled-back write does not move `data_version` — so without the rollback the phantom
      # var expanded in every send for the rest of the session, and the next committing write
      # would have made it real.
      c.view.env_vars.should be_empty
      Gori::Settings.project_env_vars.should be_empty
    end
  end

  it "says a rolled-back env delete did NOT delete" do
    with_env_controller do |c, _host, session|
      Gori::Env.save_project(session.store, [{"TOKEN", "sekrit"}]).should be_true
      c.view.reload_env_vars
      c.view.env_vars.size.should eq(1)
    end

    with_env_controller do |c, host, session|
      Gori::Env.save_project(session.store, [{"TOKEN", "sekrit"}])
      c.view.reload_env_vars
      session.store.close
      c.env_delete_var # FakeHost#confirm runs the action

      host.statuses.last.should contain("NOT deleted")
      # The row is back, because the store still has it — see the save example above.
      c.view.env_vars.should eq([{"TOKEN", "sekrit"}])
      Gori::Settings.project_env_vars.should eq([{"TOKEN", "sekrit"}])
    end
  end

  # The wiring, one link up from `ProjectView#reload_env_vars`. The link ABOVE this one —
  # `Runner#apply_external_change` calling `Env.load_project` so the global is fresh when this
  # runs — needs a live shell (and a tty) to drive, so it is not pinned here; this is the seam
  # that is.
  it "adopts a peer's env change on the next external-change tick" do
    with_env_controller do |c, _host, _session|
      c.view.env_vars.should be_empty
      # What `Runner#apply_external_change` leaves behind after reloading the global.
      Gori::Settings.project_env_vars = [{"PEER", "9"}]
      c.on_external_change
      # Stale, this list was about to be written back over the store — deleting PEER.
      c.view.env_vars.should eq([{"PEER", "9"}])
    end
  end

  it "reports the total on a committed save" do
    with_env_controller do |c, host, _session|
      c.env_add_var
      type_keys(c, "TOKEN sekrit")
      c.handle_body_key(key(Termisu::Input::Key::Enter))
      host.statuses.last.should contain("env var saved")
    end
  end

  it "does not close the add row on a ⌫ with the caret at the start" do
    with_env_controller do |c, _host, _session|
      c.env_add_var
      type_keys(c, "TOKEN abc123")
      c.handle_body_key(key(Termisu::Input::Key::Left))
      c.handle_body_key(key(Termisu::Input::Key::Left))
      12.times { c.handle_body_key(key(Termisu::Input::Key::Left)) }
      c.handle_body_key(key(Termisu::Input::Key::Backspace))

      c.view.env_adding?.should be_true # the row (and the line in it) survived
      c.handle_body_key(key(Termisu::Input::Key::Enter))
      c.view.env_vars.should eq([{"TOKEN", "abc123"}])
    end
  end
end
