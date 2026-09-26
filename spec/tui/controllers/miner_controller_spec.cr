require "../../spec_helper"
require "../../support/fake_host"
require "file_utils"

include Gori::Tui

private MINER_CA = File.tempname("gori-miner-ca")
Spec.after_suite { FileUtils.rm_rf(MINER_CA) }

private def with_miner_controller(&)
  root = File.tempname("gori-miner-ctl")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("miner")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(MINER_CA), Gori::Verbs.registry, project)
  begin
    yield MinerController.new(FakeHost.new(session)), session
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def seed_miner_flow(store, url : String) : Int64
  pair = Gori::Import::Builder.complete_flow(
    Time.utc.to_unix_ms * 1000, url, "GET",
    Gori::Import::Builder::Headers.new, nil, "HTTP/1.1",
    200, "OK", Gori::Import::Builder::Headers.new, nil, "text/html", nil,
    source: Gori::FlowSource::Kind::Import)
  store.insert_import_batch([{pair.request, pair.response}])
  store.search(Gori::QL::EMPTY, 1).first.id
end

# Spin the scheduler until the worker's answer lands (the Runner does this once per tick).
private def drain_until_landed(ctl : MinerController) : Nil
  deadline = Time.instant + 10.seconds
  until ctl.drain_seed_names
    raise "seed-name scan never landed" if Time.instant > deadline
    sleep 1.millisecond
  end
end

# The controller's half of a History mine's seed names: the scan runs off the event loop and
# lands on the popup through `drain_seed_names`. The names themselves are pinned in
# spec/param_inventory_spec.cr (`.seed_names`).
describe MinerController do
  describe "#scan_seed_names (#1231)" do
    it "seeds a History mine with the host's other endpoints' names" do
      with_miner_controller do |ctl, session|
        seed_miner_flow(session.store, "https://acme.test/orders?tenant=1")
        id = seed_miner_flow(session.store, "https://acme.test/invoices?page=1")
        ov = MineConfigOverlay.new(ctl.build_seed_from_flow(id) || raise "no seed for flow #{id}")
        ctl.scan_seed_names(ov)
        ov.seeding?.should be_true
        drain_until_landed(ctl)
        ov.seeding?.should be_false
        ov.build_config.seed_names.should eq(["tenant"])
      end
    end

    # Start cancels it, and a newer popup's scan supersedes it: either way the old answer is
    # dropped rather than landed on a popup that no longer decides anything.
    it "drops a cancelled scan's answer" do
      with_miner_controller do |ctl, session|
        seed_miner_flow(session.store, "https://acme.test/orders?tenant=1")
        id = seed_miner_flow(session.store, "https://acme.test/invoices?page=1")
        ov = MineConfigOverlay.new(ctl.build_seed_from_flow(id) || raise "no seed for flow #{id}")
        ctl.scan_seed_names(ov)
        ctl.cancel_seed_scan
        deadline = Time.instant + 2.seconds
        until Time.instant > deadline
          ctl.drain_seed_names.should be_false
          sleep 5.milliseconds
        end
        ov.build_config.seed_names.should be_empty
      end
    end

    it "does not scan for a seed with no flow behind it" do
      with_miner_controller do |ctl, _|
        seed = ctl.build_seed_from_request("https://acme.test", "GET /x HTTP/1.1\nHost: acme.test\n\n", false, nil)
        ov = MineConfigOverlay.new(seed)
        ctl.scan_seed_names(ov)
        ov.seeding?.should be_false
      end
    end
  end
end
