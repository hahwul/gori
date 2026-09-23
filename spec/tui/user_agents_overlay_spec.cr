require "../spec_helper"

include Gori::Tui

private def ua_key(key : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(key, char: char)
end

private def type_into(ov : UserAgentsOverlay, text : String) : Nil
  text.each_char do |c|
    if c == '\n'
      ov.handle_key(ua_key(Termisu::Input::Key::Enter))
    else
      ov.handle_key(ua_key(Termisu::Input::Key.from_char(c), c))
    end
  end
end

private def with_user_agents(list : Array(String), &)
  previous = Gori::Settings.user_agents
  Gori::Settings.user_agents = list
  begin
    yield
  ensure
    Gori::Settings.user_agents = previous
  end
end

describe UserAgentsOverlay do
  # Never pre-filled with the built-in list: an untouched save would pin today's versions.
  it "opens empty over the built-in list and on the operator's list when there is one" do
    with_user_agents([] of String) { UserAgentsOverlay.new.parsed.should eq([] of String) }
    with_user_agents(["A/1.0", "B/2.0"]) { UserAgentsOverlay.new.parsed.should eq(["A/1.0", "B/2.0"]) }
  end

  # The peer tick reloads `Settings.user_agents` under an open editor (#1218); an untouched
  # editor closing must not write the list it opened on back over the peer's.
  it "has nothing to write when left as it opened, even after the live list moved" do
    with_user_agents(["A/1.0"]) do
      ov = UserAgentsOverlay.new
      Gori::Settings.user_agents = ["Peer/1.0"]
      ov.edited_list.should be_nil
      type_into(ov, "B/2.0\n") # the cursor opens at the top
      ov.edited_list.should eq(["B/2.0", "A/1.0"])
    end
  end

  it "commits on esc with the typed lines" do
    with_user_agents([] of String) do
      ov = UserAgentsOverlay.new
      type_into(ov, "A/1.0 (X11)\n\nB/2.0")
      ov.handle_key(ua_key(Termisu::Input::Key::Escape)).should eq(:commit)
      ov.user_agents.should eq(["A/1.0 (X11)", "B/2.0"])
    end
  end

  # The line a header cannot carry refuses the close and names itself. Typed keys cannot put a
  # control byte in the buffer, so the bad line arrives the way one really could: already in it.
  it "refuses to close over an unusable line while its card is on screen" do
    with_user_agents(["A/1.0", "B\t2.0"]) do
      ov = UserAgentsOverlay.new
      ov.handle_key(ua_key(Termisu::Input::Key::Escape)).should eq(:stay)
      ov.refusal.not_nil!.should contain("line 2")
    end
  end
end
