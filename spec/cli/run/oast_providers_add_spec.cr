require "../../spec_helper"
require "json"

# `gori run oast providers add --format json` (#1117): a script configuring a provider had to
# scrape `p_3` out of "OAST provider 'p_3' created.". The object is the provider's element of
# `providers list --format json` — the same `oast_provider_json`, read back through the same
# `Oast.provider_configs` — so `id` is the scope-qualified key every other providers verb takes.
module Gori::CLI::Run
  def self.oast_provider_added_output_for_spec(store : Store, id : Int64, format : Symbol) : String
    oast_provider_added_output(store, id, format)
  end

  def self.oast_provider_json_for_spec(c : Oast::ProviderConfig, show_tokens : Bool) : String
    JSON.build { |j| oast_provider_json(j, c, show_tokens) }
  end
end

describe "gori run oast providers add --format json" do
  it "prints the new provider's listing object, its key as the id" do
    with_store do |store|
      row = store.insert_oast_provider("private", "interactsh", "https://oast.acme.test", "s3cret", true, 0)
      o = JSON.parse(Gori::CLI::Run.oast_provider_added_output_for_spec(store, row, :json))
      o["id"].as_s.should eq("p_#{row}")
      o["scope"].as_s.should eq("project")
      o["host"].as_s.should eq("https://oast.acme.test")
      # The listing's default: `add` has no --show-tokens, and its answer lands in logs.
      o["token"].as_s.should eq("[REDACTED]")

      config = Gori::Oast.provider_configs(store).find! { |c| c.key == "p_#{row}" }
      listed = JSON.parse(Gori::CLI::Run.oast_provider_json_for_spec(config, false))
      o.as_h.keys.should eq(listed.as_h.keys)
      o.should eq(listed)
    end
  end

  it "keeps a tokenless provider's token null, as the listing does" do
    with_store do |store|
      row = store.insert_oast_provider("public", "interactsh", "https://oast.pro", nil, false, 0)
      o = JSON.parse(Gori::CLI::Run.oast_provider_added_output_for_spec(store, row, :json))
      o["token"].raw.should be_nil
      o["enabled"].as_bool.should be_false
    end
  end

  it "keeps the text sentence unchanged" do
    with_store do |store|
      Gori::CLI::Run.oast_provider_added_output_for_spec(store, 3_i64, :text)
        .should eq("OAST provider 'p_3' created.")
    end
  end
end
