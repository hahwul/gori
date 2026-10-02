require "../../spec_helper"
require "../../support/fake_host"
require "file_utils"

include Gori::Tui

# The JWT and Cookie tabs are one workbench over two signature schemes: the same sub-tab
# lifecycle, the same INPUT editor in INS/READ, the same SECRET field, the same read-only
# DECODED / OUTPUT cards and the same focus ring, with the lens panes each tool's own. Every
# example here runs against BOTH controllers, so the half they share is pinned as one
# contract — and a difference between them shows up as a failing tool, not a silent drift.

private WB_CA = File.tempname("gori-workbench-ca")
Spec.after_suite { FileUtils.rm_rf(WB_CA) }

private JWT_TOKEN    = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
private FLASK_COOKIE = "eyJ1c2VyX2lkIjo0MiwiYWRtaW4iOnRydWUsIm5hbWUiOiJhbGljZSJ9.am71Yg.gd2MWkbBsGdhg4rScrYWBdGoj-Q"

# What differs per tool, as data: the toast name, what one session holds, the panes of each
# lens, which of them are read-only, and which are multi-line second-lens editors.
private record WbTool, name : String, noun : String, lens : Symbol, lens_toast : String,
  decode_panes : Array(Symbol), second_panes : Array(Symbol), readonly : Array(Symbol),
  editors : Array(Symbol), seed : String

private JWT_TOOL = WbTool.new("JWT", "token", :encode, "ENCODE lens",
  [:input, :decoded, :attacks], [:header, :payload, :secret, :output],
  [:decoded, :attacks, :output], [:header, :payload], JWT_TOKEN)
private COOKIE_TOOL = WbTool.new("Cookie", "cookie", :forge, "FORGE lens",
  [:input, :decoded, :opts, :secret], [:payload, :opts, :secret, :output],
  [:decoded, :output], [:payload], FLASK_COOKIE)

private def with_wb_session(&)
  root = File.tempname("gori-workbench")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("workbench")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(WB_CA), Gori::Verbs.registry, project)
  begin
    yield session
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# Expand the block once per workbench tool, each on a fresh controller + host. A macro rather
# than a yielding method: the two controllers share no type narrower than `TabController`, so a
# block typed over both would lose every workbench method.
private macro each_tool(&block)
  {% for tool in [{JwtController, JWT_TOOL}, {CookieController, COOKIE_TOOL}] %}
    with_wb_session do |%session|
      {{ block.args[1].id }} = FakeHost.new(%session)
      {{ block.args[0].id }} = {{ tool[0] }}.new({{ block.args[1].id }})
      {{ block.args[2].id }} = {{ tool[1] }}
      {{ block.body }}
    end
  {% end %}
end

private def cur_of(ctl : JwtController) : JwtSession
  ctl.@sessions[ctl.@idx]
end

private def cur_of(ctl : CookieController) : CookieSession
  ctl.@sessions[ctl.@idx]
end

private def second_editor(ctl : JwtController) : TextArea
  cur_of(ctl).header
end

private def second_editor(ctl : CookieController) : TextArea
  cur_of(ctl).payload
end

# The tools spell the shared verbs with their own prefix.
private def new_session(c : JwtController)
  c.jwt_new
end

private def new_session(c : CookieController)
  c.cookie_new
end

private def close_session(c : JwtController)
  c.jwt_close
end

private def close_session(c : CookieController)
  c.cookie_close
end

private def duplicate_session(c : JwtController)
  c.jwt_duplicate
end

private def duplicate_session(c : CookieController)
  c.cookie_duplicate
end

private def session_from_text(c : JwtController, t : String)
  c.jwt_from_text(t)
end

private def session_from_text(c : CookieController, t : String)
  c.cookie_from_text(t)
end

private def copy_pane(c : JwtController)
  c.jwt_copy
end

private def copy_pane(c : CookieController)
  c.cookie_copy
end

private def pane_copy_text(c : JwtController)
  c.jwt_copy_text
end

private def pane_copy_text(c : CookieController)
  c.cookie_copy_text
end

private def copy_output(c : JwtController)
  c.jwt_copy_token
end

private def copy_output(c : CookieController)
  c.cookie_copy_output
end

private def read_mode?(c : JwtController)
  c.jwt_read_mode?
end

private def read_mode?(c : CookieController)
  c.cookie_read_mode?
end

private def selection_active?(c : JwtController)
  c.jwt_selection_active?
end

private def selection_active?(c : CookieController)
  c.cookie_selection_active?
end

private def selection_text(c : JwtController)
  c.jwt_selection_text
end

private def selection_text(c : CookieController)
  c.cookie_selection_text
end

private def select_line(c : JwtController)
  c.jwt_select_line
end

private def select_line(c : CookieController)
  c.cookie_select_line
end

private def clear_selection(c : JwtController)
  c.jwt_clear_selection
end

private def clear_selection(c : CookieController)
  c.cookie_clear_selection
end

private def rename_at(c : JwtController, idx : Int32, name : String)
  c.view_at(idx).try { |v| c.apply_rename(v, name) }
end

private def rename_at(c : CookieController, idx : Int32, name : String)
  c.view_at(idx).try { |v| c.apply_rename(v, name) }
end

private def wkey(k : Termisu::Input::Key, mods : Termisu::Input::Modifier = :none,
                 char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, mods, char)
end

private def wchar(c : Char) : Termisu::Event::Key
  wkey(Termisu::Input::Key.from_char(c), char: c)
end

private def wtype(ctl, text : String) : Nil
  text.each_char { |c| ctl.handle_body_key(wchar(c)) }
end

# Focus `pane` in the session's current lens by walking the ring from its first pane.
private def focus_pane(ctl, pane : Symbol) : Nil
  ctl.focus_first
  until cur_of(ctl).pane == pane
    raise "no #{pane} in this lens" unless ctl.pane_advance(1)
  end
end

private def to_second_lens(ctl) : Nil
  ctl.toggle_mode if cur_of(ctl).mode == :decode
end

private def with_clipboard_off(&)
  prev = Gori::Settings.clipboard_osc52?
  Gori::Settings.clipboard_osc52 = false
  begin
    yield
  ensure
    Gori::Settings.clipboard_osc52 = prev
  end
end

describe "the JWT and Cookie workbench controllers" do
  describe "sub-tab lifecycle" do
    it "opens, duplicates and closes sessions with the tool's toasts, keeping at least one" do
      each_tool do |ctl, host, t|
        new_session(ctl)
        host.statuses.last.should eq("new #{t.name} session (2 open)")
        host.focus_requests.last.should eq(:body)
        ctl.subtab_index.should eq(1)
        duplicate_session(ctl)
        host.statuses.last.should eq("duplicated #{t.name} session (3 open)")
        ctl.subtab_index.should eq(2)
        close_session(ctl)
        host.statuses.last.should eq("session closed (2 open)")
        close_session(ctl)
        host.statuses.last.should eq("session closed")
        close_session(ctl) # the last one is replaced by a blank, never removed
        host.statuses.last.should eq("session closed")
        ctl.subtab_labels.should eq(["1:empty"])
      end
    end

    it "seeds a new session from sent text, stripped, and jumps to it" do
      each_tool do |ctl, host, t|
        sent = "  #{t.seed}\n"
        session_from_text(ctl, sent)
        host.statuses.last.should eq("sent selection to #{t.name} (#{sent.bytesize}b)")
        ctl.subtab_index.should eq(1)
        cur_of(ctl).input.text.should eq(t.seed)
        cur_of(ctl).decoded.should_not be_empty
        ctl.subtab_labels[0].should eq("1:empty")
      end
    end

    it "duplicates and closes the MARKED sub-tabs as a batch, the close behind a confirm" do
      each_tool do |ctl, host, t|
        new_session(ctl)
        ctl.toggle_subtab_mark(0)
        ctl.toggle_subtab_mark(1)
        duplicate_session(ctl)
        host.statuses.last.should eq("duplicated 2 sessions (4 open)")
        close_session(ctl)
        host.confirms.last.should eq({"CLOSE #{t.name.upcase} SESSIONS",
                                      "Close 2 sub-tabs?\nEach #{t.noun} and its edits are discarded."})
        host.statuses.last.should eq("closed 2 sub-tabs")
        ctl.subtab_labels.size.should eq(2)
      end
    end

    it "labels a chip by its custom name, capped at 18 columns, and a blank rename reverts it" do
      each_tool do |ctl, _host, _t|
        rename_at(ctl, 0, "  a rather long session name  ")
        ctl.view_at(0).try(&.name).should eq("a rather long session name")
        ctl.subtab_labels.should eq(["1:a rather long ses…"])
        rename_at(ctl, 0, "   ")
        ctl.view_at(0).try(&.name).should be_nil
        ctl.subtab_labels.should eq(["1:empty"])
        ctl.view_at(1).should be_nil
      end
    end

    it "routes ^N, ^W and ^<digit> itself, ^P to the palette, and defers every other chord" do
      each_tool do |ctl, _host, _t|
        ctrl = Termisu::Input::Modifier::Ctrl
        ctl.handle_body_key(wkey(Termisu::Input::Key::LowerN, ctrl)).should be_true
        ctl.subtab_labels.size.should eq(2)
        ctl.handle_body_key(wkey(Termisu::Input::Key::Num1, ctrl)).should be_true
        ctl.subtab_index.should eq(0)
        ctl.handle_body_key(wkey(Termisu::Input::Key::LowerW, ctrl)).should be_true
        ctl.subtab_labels.size.should eq(1)
        ctl.handle_body_key(wkey(Termisu::Input::Key::LowerP, ctrl)).should be_true
        ctl.handle_body_key(wkey(Termisu::Input::Key::LowerT, ctrl)).should be_false
        ctl.handle_body_key(wkey(Termisu::Input::Key::LowerA, ctrl)).should be_false
      end
    end
  end

  describe "the INPUT editor" do
    it "hands READ-mode letters, ↵ and space to the keymap and leaves on ↑ / esc" do
      each_tool do |ctl, host, _t|
        cur_of(ctl).input_mode.should eq(InputMode::Read)
        ctl.handle_body_key(wchar('x')).should be_false
        ctl.handle_body_key(wkey(Termisu::Input::Key::Enter)).should be_false
        ctl.handle_body_key(wkey(Termisu::Input::Key::Space, char: ' ')).should be_true
        ctl.handle_body_key(wkey(Termisu::Input::Key::Up)).should be_true
        host.focus_requests.last.should eq(:subtabs)
        host.focus_requests.clear
        ctl.handle_body_key(wkey(Termisu::Input::Key::Escape)).should be_true
        host.focus_requests.should eq([:subtabs])
      end
    end

    it "types in INS and re-decodes per key; esc drops to READ in place" do
      each_tool do |ctl, host, t|
        session_from_text(ctl, t.seed)
        before = cur_of(ctl).decoded
        ctl.editor_enter_insert.should be_true
        ctl.body_badge.should eq(:editor)
        ctl.body_takes_text?.should be_true
        ctl.accepts_bulk_paste?.should be_true
        ctl.handle_body_key(wkey(Termisu::Input::Key::Home))
        wtype(ctl, "!")
        cur_of(ctl).input.text.should eq("!#{t.seed}")
        cur_of(ctl).decoded.should_not eq(before)
        host.focus_requests.clear
        ctl.handle_body_key(wkey(Termisu::Input::Key::Escape)).should be_true
        cur_of(ctl).input_mode.should eq(InputMode::Read)
        host.focus_requests.should be_empty
        # READ-mode undo restores the buffer AND re-runs the decode over it.
        ctl.editor_undo.should be_true
        cur_of(ctl).input.text.should eq(t.seed)
        cur_of(ctl).decoded.should eq(before)
      end
    end

    it "pastes into INS in bulk, re-decoding once, and refuses the paste in READ" do
      each_tool do |ctl, _host, t|
        ctl.accepts_bulk_paste?.should be_false
        ctl.paste_text("x").should be_false
        ctl.editor_enter_insert
        ctl.paste_text(t.seed).should be_true
        cur_of(ctl).input.text.should eq(t.seed)
        cur_of(ctl).decoded.should_not be_empty
      end
    end

    it "copies an INS band, then a READ selection, and clears whichever is live" do
      each_tool do |ctl, _host, t|
        session_from_text(ctl, t.seed)
        ctl.editor_enter_insert
        ctl.handle_body_key(wkey(Termisu::Input::Key::End))
        2.times { ctl.handle_body_key(wkey(Termisu::Input::Key::Left, Termisu::Input::Modifier::Shift)) }
        selection_active?(ctl).should be_true
        selection_text(ctl).should eq(t.seed[-2..])
        pane_copy_text(ctl).should eq(t.seed[-2..])
        clear_selection(ctl)
        selection_active?(ctl).should be_false
        pane_copy_text(ctl).should eq(t.seed)
        ctl.editor_exit_insert.should be_true
        select_line(ctl)
        selection_active?(ctl).should be_true
        selection_text(ctl).should eq(t.seed)
        clear_selection(ctl)
        selection_active?(ctl).should be_false
      end
    end
  end

  describe "the read-only cards" do
    it "refuses INS, reads as READ mode, and hands letters and space to the keymap" do
      each_tool do |ctl, _host, t|
        session_from_text(ctl, t.seed)
        {false, true}.each do |second|
          to_second_lens(ctl) if second
          panes = second ? t.second_panes : t.decode_panes
          (panes & t.readonly).each do |pane|
            focus_pane(ctl, pane)
            ctl.insert_key_refusal.should eq("this pane is read-only — i edits the INPUT (↹ up); intercept toggles from the tab bar")
            read_mode?(ctl).should be_true
            ctl.body_badge.should eq(:body)
            ctl.body_takes_text?.should be_false
            ctl.accepts_bulk_paste?.should be_false
            ctl.editor_pane?.should be_false
            ctl.command_section.should eq(pane)
            ctl.handle_body_key(wchar('y')).should be_false
            ctl.handle_body_key(wkey(Termisu::Input::Key::Space, char: ' ')).should be_true
          end
        end
      end
    end

    it "walks ↓ off the DECODED card into the next pane and ↑ back to INPUT" do
      each_tool do |ctl, _host, t|
        focus_pane(ctl, :decoded)
        ctl.handle_body_key(wchar('j')).should be_true
        cur_of(ctl).pane.should eq(t.decode_panes[2])
        focus_pane(ctl, :decoded)
        ctl.handle_body_key(wchar('k')).should be_true
        cur_of(ctl).pane.should eq(:input)
      end
    end

    it "says why the OUTPUT copy is refused, and copies the focused pane when there is one" do
      each_tool do |ctl, host, t|
        copy_output(ctl)
        host.statuses.last.should eq("no valid #{t.noun} to copy")
        focus_pane(ctl, :decoded)
        copy_pane(ctl)
        host.statuses.last.should eq("nothing to copy")
        session_from_text(ctl, t.seed)
        with_clipboard_off do
          copy_pane(ctl)
          host.statuses.last.should eq("copied (0b) — clipboard is off (Settings → General)")
          Register.text.should eq(t.seed)
        end
      end
    end
  end

  describe "the second lens" do
    it "types its editors live, takes a bulk paste, and re-encodes from the SECRET field" do
      each_tool do |ctl, host, t|
        ctl.toggle_mode
        host.statuses.last.should eq(t.lens_toast)
        cur_of(ctl).mode.should eq(t.lens)
        cur_of(ctl).pane.should eq(t.second_panes.first)
        ed = second_editor(ctl)
        ctl.body_badge.should eq(:editor)
        ctl.accepts_bulk_paste?.should be_true
        ctl.paste_text(%({"a":\t1})).should be_true
        ed.text.should eq(%({"a":\t1}))
        # Any further editor of the lens (the JWT PAYLOAD) takes typed keys the same way.
        t.editors[1..].each do |pane|
          focus_pane(ctl, pane)
          wtype(ctl, "{}")
        end
        signed = cur_of(ctl).output
        cur_of(ctl).output_ok?.should be_true
        signed.should_not be_empty

        focus_pane(ctl, :secret)
        ctl.accepts_bulk_paste?.should be_false
        ctl.body_badge.should eq(:editor)
        ctl.insert_key_refusal.should be_nil
        read_mode?(ctl).should be_false
        ctl.set_preedit("ㅋ").should be_true
        cur_of(ctl).secret_pre.should eq("ㅋ")
        wtype(ctl, "ab")
        cur_of(ctl).secret_pre.should eq("")
        ctl.handle_body_key(wkey(Termisu::Input::Key::Left))
        wtype(ctl, "X")
        cur_of(ctl).secret.should eq("aXb")
        cur_of(ctl).secret_cx.should eq(2)
        ctl.handle_body_key(wkey(Termisu::Input::Key::Home))
        cur_of(ctl).secret_cx.should eq(0)
        ctl.handle_body_key(wkey(Termisu::Input::Key::Backspace)) # at 0: nothing to delete
        cur_of(ctl).secret.should eq("aXb")
        ctl.handle_body_key(wkey(Termisu::Input::Key::End))
        ctl.handle_body_key(wkey(Termisu::Input::Key::Backspace))
        cur_of(ctl).secret.should eq("aX")
        cur_of(ctl).output.should_not eq(signed)
        pane_copy_text(ctl).should eq("aX")
      end
    end

    it "runs a focus ring that stops at both ends and leaves upward to the sub-tab strip" do
      each_tool do |ctl, host, t|
        {t.decode_panes, t.second_panes}.each_with_index do |panes, i|
          ctl.toggle_mode if i == 1
          ctl.focus_first
          cur_of(ctl).pane.should eq(panes.first)
          ctl.pane_advance(-1).should be_false
          seen = [cur_of(ctl).pane]
          while ctl.pane_advance(1)
            seen << cur_of(ctl).pane
          end
          seen.should eq(panes)
          ctl.focus_last
          cur_of(ctl).pane.should eq(panes.last)
        end
        ctl.focus_first
        host.focus_requests.clear
        ctl.handle_body_key(wkey(Termisu::Input::Key::Up))
        host.focus_requests.should eq([:subtabs])
      end
    end

    it "keeps the Editor scope on INPUT alone" do
      each_tool do |ctl, _host, t|
        ctl.editor_pane?.should be_true
        ctl.editor_text_buffer.should_not be_nil
        ctl.toggle_mode
        (t.second_panes - t.readonly).each do |pane|
          focus_pane(ctl, pane)
          ctl.editor_pane?.should be_false
          ctl.editor_text_buffer.should be_nil
          ctl.editor_enter_insert.should be_false
          ctl.editor_exit_insert.should be_false
          ctl.body_takes_text?.should be_true
        end
      end
    end
  end
end
