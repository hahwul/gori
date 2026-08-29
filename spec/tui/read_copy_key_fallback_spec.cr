require "../spec_helper"
require "file_utils"
require "../support/fake_host"

# `y` with NOTHING selected copies the WHOLE focused pane. That is the rule `Runner#read_copy`
# states for every read pane in the tree ("selection if active, else the whole focused pane"),
# and the two panes here are the ones where the operator's `y` never reached it: both are
# raw-dispatched by their controller AHEAD of the keymap, and both fell back to the caret's own
# LINE instead. So the pane's two copy keys disagreed — `^Y` (project.copy / issue.copy → the
# verb → read_copy) copied the whole description/notes, `y` copied one line of it.
#
# The assertions are on WHICH branch ran, read off the toast, because the two branches word
# their status differently ("copied Nb to clipboard" for a selection, "copied description/notes
# to clipboard (Nb)" for the whole pane). `Settings.clipboard_osc52` is off for the duration:
# `Clipboard.copy` then returns 0 without touching the tty, which is what keeps a spec run from
# writing OSC 52 at the developer's terminal and taking their clipboard with it.

# The CA is the slow part of standing a Session up and nothing here asserts about it.
private READ_COPY_CA = File.tempname("gori-read-copy-ca")
Spec.after_suite { FileUtils.rm_rf(READ_COPY_CA) }

private def with_session(&)
  root = File.tempname("gori-read-copy")
  session = nil
  begin
    Dir.mkdir_p(root)
    project = Gori::ProjectRegistry.new(root).temp("readcopy")
    session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
      Gori::Proxy::Tls::CertAuthority.load_or_create(READ_COPY_CA), Gori::Verbs.registry, project)
    host = FakeHost.new(session)
    prev = Gori::Settings.clipboard_osc52?
    Gori::Settings.clipboard_osc52 = false
    begin
      yield host, session
    ensure
      Gori::Settings.clipboard_osc52 = prev
    end
  ensure
    session.try(&.close)
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def key(k : Termisu::Input::Key, mods : Termisu::Input::Modifier = :none,
                char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, mods, char)
end

private Y = -> { key(Termisu::Input::Key::LowerY, :none, 'y') }

private TEXT = "alpha\nbravo\ncharlie"

# One interaction as the poller would deliver it — enough lines in the raw request for the
# detail pane to have a caret line that is not the whole pane.
private def interaction : Gori::Oast::Interaction
  Gori::Oast::Interaction.new(
    unique_id: "uid-000001",
    protocol: "dns",
    method: nil,
    source_ip: "203.0.113.7",
    full_id: "000001.oast.test",
    raw_request: ";; QUESTION SECTION:\n;000001.oast.test. IN A\n;; trailing",
    raw_response: ";; ANSWER SECTION:\n000001.oast.test. 60 IN A 203.0.113.1",
    at: Time.unix(1_700_000_000_i64))
end

describe "bare `y` in a raw-dispatched read pane" do
  describe "the Project description" do
    it "copies the WHOLE description when nothing is selected" do
      with_session do |host, _session|
        ctl = Gori::Tui::ProjectController.new(host)
        ctl.view.replace_desc(TEXT)
        ctl.view.pane.should eq(:desc)
        ctl.view.desc_selection?.should be_false
        # What the pane's own getter answers with no band — the caret's line, and the old
        # payload of this keypress.
        ctl.view.desc_copy_text.should eq("alpha")
        ctl.view.desc_copy_all.should eq(TEXT)

        ctl.handle_body_key(Y.call).should be_true
        host.statuses.last.should start_with("copied description to clipboard")
      end
    end

    it "still copies just the selection when one is held" do
      with_session do |host, _session|
        ctl = Gori::Tui::ProjectController.new(host)
        ctl.view.replace_desc(TEXT)
        ctl.view.desc_select_line
        ctl.view.desc_selection?.should be_true

        ctl.handle_body_key(Y.call).should be_true
        host.statuses.last.should start_with("copied 0b to clipboard") # 0b: the clipboard is off
      end
    end
  end

  describe "an Issue's notes" do
    it "copies the WHOLE notes when nothing is selected" do
      with_session do |host, session|
        store = session.store
        id = store.insert_issue("reflected param", Gori::Store::Severity::Medium, "acme.test", nil)
        store.update_issue(id, notes: TEXT).should be_true
        ctl = Gori::Tui::IssuesController.new(host)
        ctl.view.reload(store)
        ctl.view.open_detail(store).should be_true
        ctl.view.notes_select_line     # the one public route into the notes pane…
        ctl.view.notes_clear_selection # …minus the selection it plants
        ctl.view.notes_focused?.should be_true
        ctl.view.notes_selection?.should be_false
        ctl.view.notes_copy_text.should eq("alpha")
        ctl.view.notes_copy_all.should eq(TEXT)

        ctl.handle_detail_key(Y.call).should be_true
        host.statuses.last.should start_with("copied notes to clipboard")
      end
    end

    it "still copies just the selection when one is held" do
      with_session do |host, session|
        store = session.store
        id = store.insert_issue("reflected param", Gori::Store::Severity::Medium, "acme.test", nil)
        store.update_issue(id, notes: TEXT).should be_true
        ctl = Gori::Tui::IssuesController.new(host)
        ctl.view.reload(store)
        ctl.view.open_detail(store).should be_true
        ctl.view.notes_select_line
        ctl.view.notes_selection?.should be_true

        ctl.handle_detail_key(Y.call).should be_true
        host.statuses.last.should start_with("copied 0b to clipboard")
      end
    end
  end
end

# Not a fallback bug like the two above but the same key in the same kind of pane: OAST's
# callback detail swallowed EVERY key it did not itself handle, so the `y copy · x line` its
# footer names were both dead — `y` reached no copy at all and `x` never got out to its chord.
describe "bare `y` in the OAST callback detail" do
  it "copies the callback, and leaves `x` to the keymap" do
    with_session do |host, session|
      store = session.store
      sid = store.insert_oast_session(nil, "interactsh", "https://oast.test",
        "c0rr3lat10n", "s3cret", nil, nil)
      ctl = Gori::Tui::OastController.new(host)
      ctl.callbacks_sub?.should be_true
      ctl.@oast_events.send(Gori::Oast::CallbackEvent.new(sid, interaction))
      ctl.drain_events.should be_true

      ctl.handle_body_key(key(Termisu::Input::Key::Enter)).should be_true # ↵ opens the detail
      ctl.oast_detail_readable?.should be_true

      ctl.handle_body_key(Y.call).should be_true
      host.statuses.last.should start_with("copied all (")

      # `x` is oast.select-line, a plain chord: the pane must hand it back, not eat it.
      ctl.handle_body_key(key(Termisu::Input::Key::LowerX, :none, 'x')).should be_false
    end
  end
end
