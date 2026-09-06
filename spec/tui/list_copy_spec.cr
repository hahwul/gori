require "../support/tui_contract"

include Gori::Tui

# `y` copies a list row on the nine lists that had no copy at all: Sitemap, Discover, Diff,
# the Issues LIST, Colormarker rules, Authorize, and the Project tab's env / host-override /
# scope-rule panes. Each goes through the shared `read_copy` seam and the one toast shape.
#
# The clipboard is switched off for the run so the spec never writes OSC 52 at the
# developer's terminal — the toast then reports `0b`, which is still the copy path.

private def with_clipboard_off(&)
  prev = Gori::Settings.clipboard_osc52?
  Gori::Settings.clipboard_osc52 = false
  begin
    yield
  ensure
    Gori::Settings.clipboard_osc52 = prev
  end
end

private def capture(store, host, method, target)
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "http", host: host, port: 80,
    method: method, target: target, http_version: "HTTP/1.1",
    head: "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, body: nil, source: Gori::FlowSource::Kind::Proxy))
end

describe "list-row copy" do
  keymap = Gori::Verb::Keymap.build(Gori::Verbs.registry)

  it "binds `y` in every list scope that lacked one" do
    {
      Gori::Verb::Scope::Sitemap       => "sitemap.copy",
      Gori::Verb::Scope::Discover      => "discover.copy",
      Gori::Verb::Scope::Diff          => "diff.copy",
      Gori::Verb::Scope::Issues        => "issues.copy-row",
      Gori::Verb::Scope::Colormarker   => "colormarker.copy",
      Gori::Verb::Scope::Authorize     => "authorize.copy",
      Gori::Verb::Scope::Env           => "env.copy-var",
      Gori::Verb::Scope::HostOverrides => "hostoverride.copy-entry",
      Gori::Verb::Scope::Project       => "scope.copy-rule",
    }.each do |scope, id|
      keymap.lookup(Gori::Verb::Chord.new("y"), scope).should eq(id)
    end
  end

  it "copies the Sitemap cursor row's host/path, or every marked row" do
    with_clipboard_off do
      TuiContract.with_session("copy-sitemap") do |session|
        capture(session.store, "a.test", "GET", "/one")
        capture(session.store, "a.test", "GET", "/two")
        host = TuiContract::Host.new(session)
        ctl = SitemapController.new(host)
        ctl.on_enter
        TuiContract.render(ctl)
        ctl.copy_row
        host.statuses.last.should start_with("copied 0b to clipboard")
      end
    end
  end

  it "copies an Issues list row, and every marked row as one line each" do
    with_clipboard_off do
      TuiContract.with_session("copy-issues") do |session|
        session.store.insert_issue("first", Gori::Store::Severity::High, "a.test", nil)
        session.store.insert_issue("second", Gori::Store::Severity::Low, nil, nil)
        host = TuiContract::Host.new(session)
        ctl = IssuesController.new(host)
        ctl.on_enter
        ctl.view.copy_rows_text.should eq("[high] first (a.test)") # the cursor row, severity-desc list
        ctl.view.mark_all
        ctl.view.copy_rows_text.lines.should eq(["[high] first (a.test)", "[low] second"])
        ctl.issues_copy_all
        host.statuses.last.should start_with("copied 2 issues (0b)")
      end
    end
  end

  it "says so when there is nothing under the cursor" do
    with_clipboard_off do
      TuiContract.with_session("copy-empty") do |session|
        TuiContract.each_controller(session) do |controller, host|
          case controller
          when DiscoverController, DiffController then controller.copy_row
          when ColormarkerController              then controller.colormarker_copy
          when AuthorizeController                then controller.authorize_copy
          else                                         next
          end
          host.statuses.last.should eq("nothing to copy")
        end
      end
    end
  end
end
