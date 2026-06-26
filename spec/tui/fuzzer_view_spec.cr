require "../spec_helper"

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
