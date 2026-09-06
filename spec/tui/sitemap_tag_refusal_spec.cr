require "../spec_helper"
require "../support/fake_host"
require "../support/memory_backend"
require "file_utils"

include Gori::Tui

# `Store#set_sitemap_tag` answers whether the write COMMITTED — its own comment says the answer
# exists because dropping it "made every caller report the change for a rolled-back batch" — and
# the Sitemap tag editor was the caller that dropped it. A project whose writer a peer holds (or
# an unwritable one) reported "tagged: <memo>", stamped the memo onto the tree in place, and let
# the next reload take it back with no word: the memo was on nobody's disk. MCP's
# `set_sitemap_tag` has always refused in these terms ("tag NOT applied … the node is unchanged").
#
# `session.store.close` is the lever: `commit_tag` reaches the write with no store READ in
# between, so nothing refuses earlier.

private SITEMAP_TAG_CA = File.tempname("gori-sitemap-tag-ca")
Spec.after_suite { FileUtils.rm_rf(SITEMAP_TAG_CA) }

private def with_sitemap_controller(&)
  root = File.tempname("gori-sitemap-tag")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("sitemaptag")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(SITEMAP_TAG_CA), Gori::Verbs.registry, project)
  begin
    host = FakeHost.new(session)
    yield SitemapController.new(host), host, session
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# One captured endpoint, so the tree has a real (host, path) row to tag.
private def seed_endpoint(store) : Nil
  pair = Gori::Import::Builder.complete_flow(
    Time.utc.to_unix_ms * 1000, "https://acme.test/admin", "GET",
    Gori::Import::Builder::Headers.new, nil, "HTTP/1.1",
    200, "OK", Gori::Import::Builder::Headers.new, nil, "text/html", nil,
    source: Gori::FlowSource::Kind::Import)
  store.insert_import_batch([{pair.request, pair.response}])
end

private def rendered(view : SitemapView) : MemoryBackend
  backend = MemoryBackend.new(100, 12)
  view.render(Screen.new(backend), Rect.new(0, 0, 100, 12))
  backend
end

private def enter : Termisu::Event::Key
  Termisu::Event::Key.new(Termisu::Input::Key::Enter)
end

# Put the cursor on the `/admin` leaf: row 0 is the host, row 1 its only child.
private def select_admin(view : SitemapView) : Nil
  view.move(1)
end

describe "Gori::Tui::SitemapController tag editor" do
  it "saves a tag and reports it" do
    with_sitemap_controller do |controller, host, session|
      seed_endpoint(session.store)
      controller.reload
      select_admin(controller.view)

      controller.sitemap_tag
      "checked".each_char { |c| controller.view.tag_insert(c) }
      controller.handle_tag_key(enter)

      host.statuses.last.should eq("tagged: checked")
      session.store.sitemap_tags[{"acme.test", "/admin"}]?.should eq("checked")
      rendered(controller.view).contains?("checked").should be_true
    end
  end

  it "refuses, names the count, and leaves the tree unstamped when the write does not commit" do
    with_sitemap_controller do |controller, host, session|
      seed_endpoint(session.store)
      controller.reload
      select_admin(controller.view)

      controller.sitemap_tag
      "checked".each_char { |c| controller.view.tag_insert(c) }
      session.store.close # every write from here answers false

      controller.handle_tag_key(enter)

      # `<noun> NOT <verbed> (<cause>) — <consequence>`, the strip's refusal template.
      host.statuses.last.should eq("1 path NOT tagged (project busy) — try again")
      host.statuses.should_not contain("tagged: checked")
      # …and the row still shows no memo, so the screen agrees with the disk.
      rendered(controller.view).contains?("checked").should be_false
    end
  end

  # `Store#set_sitemap_tag` DELETEs on `tag.blank?` and `SitemapView#apply_tag` stamps nil on
  # the same test, so a memo of nothing but spaces is a CLEAR everywhere the write lands. The
  # strip tested `empty?` and so called it a tag.
  it "calls a whitespace-only memo a CLEAR, the way both write paths read it" do
    with_sitemap_controller do |controller, host, session|
      seed_endpoint(session.store)
      controller.reload
      select_admin(controller.view)

      controller.sitemap_tag
      "checked".each_char { |c| controller.view.tag_insert(c) }
      controller.handle_tag_key(enter)
      session.store.sitemap_tags[{"acme.test", "/admin"}]?.should eq("checked")

      controller.sitemap_tag
      controller.view.tag_buffer.size.times { controller.view.tag_backspace }
      controller.view.tag_insert(' ')
      controller.handle_tag_key(enter)

      host.statuses.last.should eq("tag cleared")
      session.store.sitemap_tags[{"acme.test", "/admin"}]?.should be_nil
    end
  end
end
