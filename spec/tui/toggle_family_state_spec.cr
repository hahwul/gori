require "../spec_helper"
require "../support/fake_host"

include Gori::Tui

# The Display… and Protocol… cards are sticky and draw each row's state (#1274 WP9):
# `TabController#menu_state` answers for the tab in front, and `#pane_captures_keys?` is what
# keeps a sticky card from coming back over a field the member just opened. The Runner cannot
# be built without a tty, so these drive the controllers it asks.

private TOGGLE_STATE_CA = File.tempname("gori-toggle-state-ca")
Spec.after_suite { FileUtils.rm_rf(TOGGLE_STATE_CA) }

private def with_toggle_host(&)
  root = File.tempname("gori-toggle-state")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("toggles")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(TOGGLE_STATE_CA), Gori::Verbs.registry, project)
  begin
    yield FakeHost.new(session)
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# Every member of the two toggle families answers with a state wherever it is live, except
# the ones that open something rather than flip it.
private STATELESS_MEMBERS = {"history.columns"}

describe "toggle-family row state (#1274 WP9)" do
  it "reads the Repeater's transport and view flags, and nothing for a non-member" do
    with_toggle_host do |host|
      ctl = RepeaterController.new(host)
      ctl.repeater_new
      v = ctl.current_view.not_nil!

      ctl.menu_state("repeater.toggle-http2").should eq("off")
      ctl.repeater_toggle_http2
      ctl.menu_state("repeater.toggle-http2").should eq("on")

      cl = ctl.menu_state("repeater.toggle-auto-content-length")
      ctl.repeater_toggle_auto_content_length
      ctl.menu_state("repeater.toggle-auto-content-length").should_not eq(cl)

      ctl.menu_state("repeater.cycle-tls-preset").should eq("off")
      ctl.repeater_cycle_tls_preset
      ctl.menu_state("repeater.cycle-tls-preset").should eq(v.tls_preset)
      v.tls_preset.should_not be_nil

      v.focus_pane(:response)
      ctl.menu_state("repeater.toggle-resp-hex").should eq("off")
      v.toggle_resp_hex
      ctl.menu_state("repeater.toggle-resp-hex").should eq("on")
      ctl.menu_state("repeater.toggle-diff").should eq("off")
      v.toggle_resp_mode
      ctl.menu_state("repeater.toggle-diff").should eq("on")
      ctl.menu_state("repeater.toggle-unicode").should eq("off")
      v.toggle_unicode_decoding
      ctl.menu_state("repeater.toggle-unicode").should eq("on")

      # Rows for another kind of tab, and rows that are not toggles, draw nothing.
      ctl.menu_state("repeater.toggle-ws-key").should be_nil
      ctl.menu_state("repeater.toggle-grpc-reframe").should be_nil
      ctl.menu_state("repeater.toggle-grpc-fields").should be_nil
      ctl.menu_state("repeater.toggle-envelope").should be_nil
      ctl.menu_state("repeater.send").should be_nil
    end
  end

  it "keeps the sticky card closed once the SNI field takes the keys" do
    with_toggle_host do |host|
      ctl = RepeaterController.new(host)
      ctl.repeater_new
      v = ctl.current_view.not_nil!
      v.focus_pane(:target)
      v.exit_target_insert! if v.target_insert?
      ctl.pane_captures_keys?.should be_false
      ctl.menu_state("repeater.toggle-sni").should eq("off")
      ctl.repeater_toggle_sni
      ctl.pane_captures_keys?.should be_true
    end
  end

  it "reads the Fuzzer's results lenses and transport" do
    with_toggle_host do |host|
      ctl = FuzzerController.new(host)
      ctl.fuzz_new
      ctl.menu_state("fuzz.matched").should eq("off")
      ctl.fuzz_toggle_matched
      ctl.menu_state("fuzz.matched").should eq("on")
      ctl.menu_state("fuzz.dist").should eq("on") # the sidebar starts shown
      ctl.fuzz_toggle_dist
      ctl.menu_state("fuzz.dist").should eq("off")
      h2 = ctl.menu_state("fuzz.toggle-http2")
      ctl.fuzz_toggle_http2
      ctl.menu_state("fuzz.toggle-http2").should_not eq(h2)
      ctl.menu_state("fuzz.toggle-sni").should eq("off")
      ctl.menu_state("fuzz.sort").should be_nil # a direct row, not a member
    end
  end

  it "reads the Sitemap's folds and the Comparer's pane" do
    with_toggle_host do |host|
      sm = SitemapController.new(host)
      before = sm.menu_state("sitemap.toggle-grouping")
      sm.sitemap_toggle_grouping
      sm.menu_state("sitemap.toggle-grouping").should_not eq(before)
      sm.menu_state("sitemap.toggle-query-fold").should eq("on") # folded by default
      sm.sitemap_toggle_query_fold
      sm.menu_state("sitemap.toggle-query-fold").should eq("off")
      sm.menu_state("sitemap.toggle-js-refs").should_not be_nil

      cmp = ComparerController.new(host)
      pane = cmp.menu_state("comparer.toggle-pane")
      cmp.view.toggle_pane
      cmp.menu_state("comparer.toggle-pane").should_not eq(pane)
      cmp.menu_state("comparer.toggle-pane").should eq("#{cmp.view.pane}s")
      cmp.menu_state("comparer.toggle-fold").should eq("off")
    end
  end

  it "reads History's follow" do
    with_toggle_host do |host|
      ctl = HistoryController.new(host)
      before = ctl.menu_state("history.toggle-follow")
      ctl.toggle_follow
      ctl.menu_state("history.toggle-follow").should_not eq(before)
      ctl.menu_state("history.columns").should be_nil
    end
  end

  it "has a state answer for every toggle-family member" do
    reg = Gori::Verbs.registry
    # Each answering site names the id in a `when` arm; a member added without one would draw
    # no ●/○ in a card whose whole point is to show them.
    arms = Dir.glob("src/gori/tui/**/*.cr").flat_map { |f| File.read_lines(f) }
      .select(&.lstrip.starts_with?("when \""))
    {Gori::Verbs::DISPLAY, Gori::Verbs::PROTOCOL}.each do |family|
      reg.select { |v| v.family == family.id }.each do |v|
        next if STATELESS_MEMBERS.includes?(v.id)
        arms.any?(&.includes?("\"#{v.id}\"")).should be_true, v.id
      end
    end
  end
end
