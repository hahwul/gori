require "../support/tui_contract"

include Gori::Tui

# `LineEdit` — the caret edits the six `/` bars and the issue-form title share: ⌃/⌥←→ by word,
# Home/End, Delete, ⌥⌫. Each bar used to answer the modified arrows with a one-character
# step and the rest with nothing.

private def key(k : Termisu::Input::Key, mods = Termisu::Input::Modifier::None, char : Char? = nil)
  Termisu::Event::Key.new(k, mods, char)
end

describe Gori::Tui::LineEdit do
  it "reads the word chords, the line ends, forward delete and the modified backspace" do
    LineEdit.action(key(Termisu::Input::Key::Left, Termisu::Input::Modifier::Ctrl)).should eq(:word_left)
    LineEdit.action(key(Termisu::Input::Key::Right, Termisu::Input::Modifier::Alt)).should eq(:word_right)
    LineEdit.action(key(Termisu::Input::Key::Home)).should eq(:home)
    LineEdit.action(key(Termisu::Input::Key::End)).should eq(:end)
    LineEdit.action(key(Termisu::Input::Key::Delete)).should eq(:delete)
    LineEdit.action(key(Termisu::Input::Key::Backspace, Termisu::Input::Modifier::Alt)).should eq(:delete_word)
    LineEdit.action(key(Termisu::Input::Key::Unknown, Termisu::Input::Modifier::Alt, '\u{7F}')).should eq(:delete_word)
    LineEdit.action(key(Termisu::Input::Key::Left)).should be_nil # the bare arrow is the bar's own
    LineEdit.action(key(Termisu::Input::Key::Backspace)).should be_nil
    LineEdit.action(key(Termisu::Input::Key::LowerA, Termisu::Input::Modifier::None, 'a')).should be_nil
  end

  it "moves by TextField's word rule and edits in place" do
    text = "status:200 host:a.test"
    LineEdit.apply(:word_left, text, text.size).should eq({text, 18}) # before `test`
    LineEdit.apply(:word_left, text, 18).should eq({text, 17})        # the `.` is its own run
    LineEdit.apply(:word_right, text, 0).should eq({text, 6})         # after `status`
    LineEdit.apply(:home, text, 9).should eq({text, 0})
    LineEdit.apply(:end, text, 9).should eq({text, text.size})
    LineEdit.apply(:delete, "abc", 1).should eq({"ac", 1})
    LineEdit.apply(:delete, "abc", 3).should eq({"abc", 3}) # nothing after the caret
    LineEdit.apply(:delete_word, "status:200 host", 15).should eq({"status:200 ", 11})
    LineEdit.apply(:delete_word, "abc", 0).should eq({"abc", 0})
  end

  it "only reports the two edits as mutating" do
    LineEdit.mutating?(:delete).should be_true
    LineEdit.mutating?(:delete_word).should be_true
    LineEdit.mutating?(:word_left).should be_false
    LineEdit.mutating?(:home).should be_false
  end
end

describe "the `/` bars take LineEdit" do
  it "moves the History bar's caret by word, jumps to its ends, and deletes forward" do
    TuiContract.with_session("line-edit-history") do |session|
      TuiContract.each_controller(session) do |controller, _host|
        next unless controller.is_a?(HistoryController)
        view = controller.view
        view.start_query
        "status:200 host:a".each_char { |c| view.query_insert(c) }
        controller.handle_query_key(key(Termisu::Input::Key::Left, Termisu::Input::Modifier::Ctrl)).should be_true
        view.query.should eq("status:200 host:a")
        controller.handle_query_key(key(Termisu::Input::Key::Home))
        controller.handle_query_key(key(Termisu::Input::Key::Delete))
        view.query.should eq("tatus:200 host:a")
        controller.handle_query_key(key(Termisu::Input::Key::End))
        controller.handle_query_key(key(Termisu::Input::Key::Backspace, Termisu::Input::Modifier::Alt))
        view.query.should eq("tatus:200 host:")
      end
    end
  end

  it "edits the Issues, Probe and Intercept bars the same way" do
    TuiContract.with_session("line-edit-bars") do |session|
      TuiContract.each_controller(session) do |controller, _host|
        case controller
        when IssuesController, ProbeController
          v = controller.view
          v.start_query
          "sev:high title".each_char { |c| v.query_insert(c) }
          controller.handle_query_key(key(Termisu::Input::Key::Backspace, Termisu::Input::Modifier::Alt))
          v.query.should eq("sev:high ")
          controller.handle_query_key(key(Termisu::Input::Key::Home))
          controller.handle_query_key(key(Termisu::Input::Key::Delete))
          v.query.should eq("ev:high ")
        when InterceptController
          v = controller.view
          v.start_query(session.store)
          "host:a method:GET".each_char { |c| v.query_insert(c) }
          controller.handle_query_key(key(Termisu::Input::Key::Backspace, Termisu::Input::Modifier::Alt))
          v.query.should eq("host:a method:")
        end
      end
    end
  end
end
