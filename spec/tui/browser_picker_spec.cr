require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

private def browser_found(id : String, name : String, kind : Gori::Browser::Kind) : Gori::Browser::Found
  Gori::Browser::Found.new(id, name, kind, "/path/#{id}")
end

private BROWSERS = [
  browser_found("chrome", "Google Chrome", Gori::Browser::Kind::Chromium),
  browser_found("firefox", "Firefox", Gori::Browser::Kind::Firefox),
]

describe Gori::Tui::BrowserPicker do
  it "moves the selection within bounds" do
    picker = BrowserPicker.new(BROWSERS)
    picker.selected.should eq(0)
    picker.move(-1)
    picker.selected.should eq(0) # clamp at the top
    picker.move(1)
    picker.selected.should eq(1)
    picker.move(1)
    picker.selected.should eq(1) # clamp at the bottom
    picker.selected_browser.try(&.id).should eq("firefox")
  end

  it "renders the title and each browser name" do
    backend = MemoryBackend.new(80, 14)
    BrowserPicker.new(BROWSERS).render(Screen.new(backend), Rect.new(0, 0, 80, 14))
    backend.contains?("OPEN BROWSER").should be_true
    backend.contains?("Google Chrome").should be_true
    backend.contains?("Firefox").should be_true
  end

  # Firefox trusts the CA via a `certutil` NSS import (see Browser.setup_firefox_profile);
  # without it the profile only gets proxy prefs and HTTPS shows cert errors. Warn on the
  # row BEFORE launch — the post-launch toast is easy to miss once focus jumps to the
  # freshly opened browser window (see issue #311).
  it "warns on the Firefox row when certutil is unavailable" do
    backend = MemoryBackend.new(80, 14)
    BrowserPicker.new(BROWSERS, false).render(Screen.new(backend), Rect.new(0, 0, 80, 14))
    backend.contains?("firefox ⚠").should be_true
  end

  it "doesn't warn when certutil is available" do
    backend = MemoryBackend.new(80, 14)
    BrowserPicker.new(BROWSERS, true).render(Screen.new(backend), Rect.new(0, 0, 80, 14))
    backend.contains?("firefox ⚠").should be_false
    backend.contains?("firefox").should be_true
  end
end
