require "../spec_helper"
require "file_utils"

include Gori::Tui

describe Gori::Tui::FuzzerView do
  it "label uses the custom name when set, else the template summary" do
    view = FuzzerView.new
    view.load_request("https://h", "GET /?x=1 HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    view.label(18).should eq("GET /?x=1") # auto-derived from the request line
    view.name = "auth fuzz"
    view.label(18).should eq("auth fuzz")
    view.name = "   " # blank → revert to the auto label
    view.label(18).should eq("GET /?x=1")
    view.name = nil
    view.label(18).should eq("GET /?x=1")
  end

  it "label truncates a long custom name" do
    view = FuzzerView.new
    view.load_request("https://h", "GET / HTTP/1.1\r\nHost: h\r\n\r\n", false, "")
    view.name = "a-very-long-custom-tab-name"
    label = view.label(8)
    label.size.should be <= 8
    label.should end_with("…")
  end
end

describe Gori::Tui::PathComplete do
  it "lists a directory's children, directories trailing a slash" do
    root = File.tempname("gori_pc")
    Dir.mkdir_p(File.join(root, "sub"))
    File.write(File.join(root, "words.txt"), "a\nb\n")
    File.write(File.join(root, "other.lst"), "x\n")
    begin
      pc = PathComplete.new
      pc.refresh("#{root}/")
      pc.open?.should be_true
      file = pc.entries.find { |e| e.label == "words.txt" }.not_nil!
      file.insert.should eq("#{root}/words.txt")
      file.dir.should be_false
      dir = pc.entries.find { |e| e.label == "sub" }.not_nil!
      dir.insert.should eq("#{root}/sub/") # trailing slash so the user keeps drilling
      dir.dir.should be_true
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "filters by the typed basename partial" do
    root = File.tempname("gori_pc")
    Dir.mkdir_p(root)
    File.write(File.join(root, "words.txt"), "")
    File.write(File.join(root, "other.txt"), "")
    begin
      pc = PathComplete.new
      pc.refresh("#{root}/wo")
      pc.entries.map(&.label).should eq(["words.txt"])
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "completes bare names from ~/.gori/wordlists with an ABSOLUTE insert (G1)" do
    home = File.tempname("gori_home")
    wl = File.join(home, "wordlists")
    Dir.mkdir_p(wl)
    File.write(File.join(wl, "rockyou.txt"), "")
    old = ENV["GORI_HOME"]?
    ENV["GORI_HOME"] = home
    begin
      pc = PathComplete.new
      pc.refresh("rock")
      hit = pc.entries.find { |e| e.label.starts_with?("rockyou.txt") }.not_nil!
      # The engine opens wordlist paths relative to CWD, so a wordlists-dir-only name
      # MUST resolve absolutely — a bare "rockyou.txt" insert would fail at run time.
      hit.insert.should eq(File.join(wl, "rockyou.txt"))
      hit.label.should contain("·~/.gori")
    ensure
      old ? (ENV["GORI_HOME"] = old) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(home)
    end
  end

  it "accept returns the highlighted insert + dir flag; move clamps at the top" do
    root = File.tempname("gori_pc")
    Dir.mkdir_p(File.join(root, "dir"))
    File.write(File.join(root, "a.txt"), "")
    begin
      pc = PathComplete.new
      pc.refresh("#{root}/")
      pc.move(-1) # clamp at the top
      pc.selected.should eq(0)
      first = pc.entries[0]
      res = pc.accept.not_nil!
      res[0].should eq(first.insert)
      res[1].should eq(first.dir)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
