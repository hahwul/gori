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

private def cur_of(ctl)
  ctl.@sessions[ctl.@idx]
end

private def second_editor(ctl : JwtController) : TextArea
  cur_of(ctl).header
end

private def second_editor(ctl : CookieController) : TextArea
  cur_of(ctl).payload
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
        ctl.new_session
        host.statuses.last.should eq("new #{t.name} session (2 open)")
        host.focus_requests.last.should eq(:body)
        ctl.subtab_index.should eq(1)
        ctl.duplicate_session
        host.statuses.last.should eq("duplicated #{t.name} session (3 open)")
        ctl.subtab_index.should eq(2)
        ctl.close_session
        host.statuses.last.should eq("session closed (2 open)")
        ctl.close_session
        host.statuses.last.should eq("session closed")
        ctl.close_session # the last one is replaced by a blank, never removed
        host.statuses.last.should eq("session closed")
        ctl.subtab_labels.should eq(["1:empty"])
      end
    end

    it "seeds a new session from sent text, stripped, and jumps to it" do
      each_tool do |ctl, host, t|
        sent = "  #{t.seed}\n"
        ctl.session_from_text(sent)
        host.statuses.last.should eq("sent selection to #{t.name} (#{sent.bytesize}b)")
        ctl.subtab_index.should eq(1)
        cur_of(ctl).input.text.should eq(t.seed)
        cur_of(ctl).decoded.should_not be_empty
        ctl.subtab_labels[0].should eq("1:empty")
      end
    end

    it "duplicates and closes the MARKED sub-tabs as a batch, the close behind a confirm" do
      each_tool do |ctl, host, t|
        ctl.new_session
        ctl.toggle_subtab_mark(0)
        ctl.toggle_subtab_mark(1)
        ctl.duplicate_session
        host.statuses.last.should eq("duplicated 2 sessions (4 open)")
        ctl.close_session
        host.confirms.last.should eq({"CLOSE #{t.name.upcase} SESSIONS",
                                      "Close 2 sub-tabs?\nEach #{t.noun} and its edits are discarded."})
        host.statuses.last.should eq("closed 2 sub-tabs")
        ctl.subtab_labels.size.should eq(2)
      end
    end

    it "labels a chip by its custom name, capped at 18 columns, and a blank rename reverts it" do
      each_tool do |ctl, _host, _t|
        ctl.apply_rename(ctl.view_at(0).not_nil!, "  a rather long session name  ")
        ctl.view_at(0).try(&.name).should eq("a rather long session name")
        ctl.subtab_labels.should eq(["1:a rather long ses…"])
        ctl.apply_rename(ctl.view_at(0).not_nil!, "   ")
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
        ctl.session_from_text(t.seed)
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
        ctl.session_from_text(t.seed)
        ctl.editor_enter_insert
        ctl.handle_body_key(wkey(Termisu::Input::Key::End))
        2.times { ctl.handle_body_key(wkey(Termisu::Input::Key::Left, Termisu::Input::Modifier::Shift)) }
        ctl.selection_active?.should be_true
        ctl.selection_text.should eq(t.seed[-2..])
        ctl.pane_copy_text.should eq(t.seed[-2..])
        ctl.clear_selection
        ctl.selection_active?.should be_false
        ctl.pane_copy_text.should eq(t.seed)
        ctl.editor_exit_insert.should be_true
        ctl.select_line
        ctl.selection_active?.should be_true
        ctl.selection_text.should eq(t.seed)
        ctl.clear_selection
        ctl.selection_active?.should be_false
      end
    end
  end

  describe "the read-only cards" do
    it "refuses INS, reads as READ mode, and hands letters and space to the keymap" do
      each_tool do |ctl, _host, t|
        ctl.session_from_text(t.seed)
        {false, true}.each do |second|
          to_second_lens(ctl) if second
          panes = second ? t.second_panes : t.decode_panes
          (panes & t.readonly).each do |pane|
            focus_pane(ctl, pane)
            ctl.insert_key_refusal.should eq("this pane is read-only — i edits the INPUT (↹ up); intercept toggles from the tab bar")
            ctl.read_mode?.should be_true
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
        ctl.copy_output
        host.statuses.last.should eq("no valid #{t.noun} to copy")
        focus_pane(ctl, :decoded)
        ctl.copy_pane
        host.statuses.last.should eq("nothing to copy")
        ctl.session_from_text(t.seed)
        with_clipboard_off do
          ctl.copy_pane
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
        ctl.read_mode?.should be_false
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
        ctl.pane_copy_text.should eq("aX")
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
