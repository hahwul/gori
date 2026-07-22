require "./spec_helper"

# Configured OAST providers: the global/project merge (Oast.provider_configs) mirrors
# Probe.custom_rules — see probe_custom_rule_spec.cr for the analogous test.

private def with_store(&)
  path = File.tempname("gori-oast-config", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

describe Gori::Oast::ProviderConfig do
  it "builds a scope-qualified key that can't collide across scopes" do
    g = Gori::Oast::ProviderConfig.new("7", "g", "interactsh", "https://a", nil, true, "global")
    p = Gori::Oast::ProviderConfig.new("7", "p", "interactsh", "https://a", nil, true, "project")
    g.key.should eq("g_7")
    p.key.should eq("p_7")
    g.key.should_not eq(p.key)
  end

  it "exposes project_id only for project scope" do
    Gori::Oast::ProviderConfig.new("123", "p", "boast", "https://a", nil, true, "project").project_id.should eq(123_i64)
    Gori::Oast::ProviderConfig.new("abcd", "g", "boast", "https://a", nil, true, "global").project_id.should be_nil
  end
end

describe "Gori::Settings global-provider CRUD" do
  it "adds, updates, toggles, and deletes a global provider" do
    # These mutators call `save` (real disk I/O), so — like settings_spec.cr's save-exercising
    # examples — give this test its OWN GORI_HOME rather than writing through the shared
    # GORI_TEST_HOME: resetting just the in-memory Gori::Settings.oast_providers in `ensure`
    # would leave the shared settings.json (and @@loaded_raw) holding whatever the last `save`
    # in this test wrote, if an assertion above failed before the final delete ran.
    dir = File.tempname("gori-oast-provider-crud")
    Dir.mkdir_p(dir)
    prev = ENV["GORI_HOME"]?
    begin
      ENV["GORI_HOME"] = dir
      Gori::Settings.oast_providers = [] of Gori::Settings::OastProvider
      id = Gori::Settings.add_oast_provider("My Interactsh", "interactsh", "https://oast.pro", nil)
      Gori::Settings.oast_providers.size.should eq(1)
      Gori::Settings.oast_providers.first.enabled.should be_true

      Gori::Settings.set_oast_provider_enabled(id, false)
      Gori::Settings.oast_providers.first.enabled.should be_false

      Gori::Settings.update_oast_provider(id, "Renamed", "interactsh", "https://oast.live", "tok")
      updated = Gori::Settings.oast_providers.first
      updated.name.should eq("Renamed")
      updated.host.should eq("https://oast.live")
      updated.token.should eq("tok")

      Gori::Settings.delete_oast_provider(id)
      Gori::Settings.oast_providers.should be_empty
    ensure
      prev ? (ENV["GORI_HOME"] = prev) : ENV.delete("GORI_HOME")
      FileUtils.rm_rf(dir)
      Gori::Settings.oast_providers = [] of Gori::Settings::OastProvider
    end
  end
end

describe "Gori::Oast.provider_configs merge" do
  it "unions the global library with the project's own providers, tagged by scope" do
    with_store do |store|
      saved = Gori::Settings.oast_providers
      begin
        Gori::Settings.oast_providers = [
          Gori::Settings::OastProvider.new("g1", "Global Interactsh", "interactsh", "https://oast.pro", nil, true),
        ]
        store.insert_oast_provider("Project BOAST", "BOAST", "https://odiss.eu:2096/events", "sekret", true, 0)

        merged = Gori::Oast.provider_configs(store)
        merged.size.should eq(2)

        g = merged.find(&.global?).not_nil!
        g.name.should eq("Global Interactsh")
        g.id.should eq("g1")
        g.project_id.should be_nil

        p = merged.find { |c| !c.global? }.not_nil!
        p.name.should eq("Project BOAST")
        p.global?.should be_false
        p.project_id.should_not be_nil
      ensure
        Gori::Settings.oast_providers = saved
      end
    end
  end
end
