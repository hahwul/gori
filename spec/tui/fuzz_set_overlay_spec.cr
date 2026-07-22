require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def okey(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

private def otype(ov : FuzzSetOverlay, s : String) : Nil
  s.each_char { |c| ov.handle_key(okey(Termisu::Input::Key::LowerA, c)) }
end

private def ctrl_d : Termisu::Event::Key
  Termisu::Event::Key.new(Termisu::Input::Key::LowerD, Termisu::Input::Modifier::Ctrl)
end

describe Gori::Tui::FuzzSetOverlay do
  it "List: multi-line values build a comma-joined spec (newline = a new value)" do
    ov = FuzzSetOverlay.for_list
    ov.handle_key(okey(Termisu::Input::Key::Down)) # Type row → the values editor
    otype(ov, "admin")
    ov.handle_key(okey(Termisu::Input::Key::Enter))
    otype(ov, "root")
    spec = ov.build_spec.not_nil!
    spec.kind.should eq(:list)
    spec.value.should eq("admin,root")
  end

  it "List: typing on the Type row (before any nav) drops into the values editor" do
    # ^L opens focused on the Type selector; the first keystroke/paste must not be lost.
    ov = FuzzSetOverlay.for_list
    otype(ov, "admin")
    ov.handle_key(okey(Termisu::Input::Key::Enter))
    otype(ov, "root")
    ov.build_spec.not_nil!.value.should eq("admin,root")
  end

  it "Numbers: bounds above Int32::MAX survive build_spec (Int64 range)" do
    ov = FuzzSetOverlay.for_list
    ov.handle_key(okey(Termisu::Input::Key::Right))                 # List → Numbers
    ov.handle_key(okey(Termisu::Input::Key::Down))                  # Type row → From
    5.times { ov.handle_key(okey(Termisu::Input::Key::Backspace)) } # clear "1"
    otype(ov, "3000000000")
    ov.build_spec.not_nil!.value.should eq("3000000000-100:1")
  end

  it "seeds an existing List set (comma → lines) and round-trips back to commas" do
    ov = FuzzSetOverlay.editing(Gori::Tui::SetSpec.new(:list, "a,b,c"), 0)
    ov.edit_index.should eq(0)
    ov.build_spec.not_nil!.value.should eq("a,b,c")
  end

  it "esc returns :apply; a blank List yields nil so @sets stays unchanged" do
    ov = FuzzSetOverlay.for_list
    ov.handle_key(okey(Termisu::Input::Key::Escape)).should eq(:apply)
    ov.build_spec.should be_nil
  end

  it "Numbers: the from/to/step defaults build the range grammar" do
    ov = FuzzSetOverlay.for_list
    ov.handle_key(okey(Termisu::Input::Key::Right)) # Type: List → Numbers
    spec = ov.build_spec.not_nil!
    spec.kind.should eq(:numbers)
    spec.value.should eq("1-100:1")
  end

  it "Wordlist maps to the :file kind" do
    ov = FuzzSetOverlay.for_list
    2.times { ov.handle_key(okey(Termisu::Input::Key::Right)) } # → Wordlist
    ov.handle_key(okey(Termisu::Input::Key::Down))              # → the Path field
    otype(ov, "/tmp/words.txt")
    spec = ov.build_spec.not_nil!
    spec.kind.should eq(:file)
    spec.value.should eq("/tmp/words.txt")
  end

  it "Brute builds the charset:min-max grammar from its defaults" do
    ov = FuzzSetOverlay.for_list
    4.times { ov.handle_key(okey(Termisu::Input::Key::Right)) } # → Brute
    ov.build_spec.not_nil!.value.should eq("abc:1-3")
  end

  it "cycling the Type row wraps back to List" do
    ov = FuzzSetOverlay.for_list
    5.times { ov.handle_key(okey(Termisu::Input::Key::Right)) } # list→…→brute→list
    ov.handle_key(okey(Termisu::Input::Key::Down))              # values editor
    otype(ov, "x")
    ov.build_spec.not_nil!.kind.should eq(:list)
  end

  it "seeds a Numbers set back into its from/to/step fields" do
    ov = FuzzSetOverlay.editing(Gori::Tui::SetSpec.new(:numbers, "5-50:5"), 2)
    ov.build_spec.not_nil!.value.should eq("5-50:5")
  end

  it "renders the box with the type selector and applies esc semantics" do
    ov = FuzzSetOverlay.for_list
    backend = MemoryBackend.new(120, 30)
    ov.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
    backend.contains?("PAYLOAD SET").should be_true
    backend.contains?("List").should be_true
  end

  it "^D on the wordlist Path field toggles the typed path in/out of favorites" do
    dir = File.tempname("gori-fuzz-set-overlay-favorite")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.fuzz_favorite_wordlists = [] of String

      ov = FuzzSetOverlay.for_list
      2.times { ov.handle_key(okey(Termisu::Input::Key::Right)) } # List → Wordlist
      ov.handle_key(okey(Termisu::Input::Key::Down))              # Type row → the Path field
      otype(ov, "/tmp/words.txt")

      Gori::Settings.favorite_wordlist?("/tmp/words.txt").should be_false
      ov.handle_key(ctrl_d).should eq(:stay) # doesn't apply/close the overlay
      Gori::Settings.favorite_wordlist?("/tmp/words.txt").should be_true
      # the star indicator renders alongside the Path field once favorited
      backend = MemoryBackend.new(120, 30)
      ov.render(Screen.new(backend), Rect.new(0, 0, 120, 30))
      backend.contains?("★").should be_true

      ov.handle_key(ctrl_d) # toggle back off
      Gori::Settings.favorite_wordlist?("/tmp/words.txt").should be_false

      # the path itself is untouched — ^D only manages favorites
      ov.build_spec.not_nil!.value.should eq("/tmp/words.txt")
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.fuzz_favorite_wordlists = [] of String
    end
  end
end
