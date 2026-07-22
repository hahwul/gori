require "../store"
require "../settings"

module Gori::Oast
  # A configured OAST provider, merged from both scopes: the GLOBAL library
  # (Settings.oast_providers, reusable across every project) and this PROJECT's own
  # (store.oast_providers). `Oast.provider_configs` merges both into the runtime list the
  # Providers sub-tab renders and drives register/listen from. Mirrors Probe::CustomRule /
  # Probe.custom_rules (the same global/project duality for Probe match rules).
  #
  # NOT required from oast.cr's umbrella: that engine is Store/TUI-free (driving `gori run
  # oast` and the MCP oast_* tools, neither of which touches persisted providers), so this
  # file — which pulls in Store + Settings — is required directly by its one consumer
  # (the TUI OastController).
  record ProviderConfig,
    id : String,   # global: a random hex token; project: the DB row id as text — unique PER SCOPE
    name : String,
    kind : String, # ProviderKind label
    host : String,
    token : String?,
    enabled : Bool,
    scope : String do # "global" | "project"

    # A scope-qualified key, unique across BOTH scopes (a project row id and a global hex id
    # could otherwise collide) — keys listeners and disambiguates edit/toggle/delete routing.
    def key : String
      "#{scope[0]}_#{id}"
    end

    def global? : Bool
      scope == "global"
    end

    # The project DB row id, when this entry is project-scoped (nil for global — a global
    # provider has no row in this project's DB).
    def project_id : Int64?
      global? ? nil : id.to_i64
    end
  end

  # Global first, then project — mirrors Probe.custom_rules; order only affects display,
  # since selection/toggle/delete all key off `key`, not position.
  def self.provider_configs(store : Store) : Array(ProviderConfig)
    out = [] of ProviderConfig
    Settings.oast_providers.each do |p|
      out << ProviderConfig.new(p.id, p.name, p.kind, p.host, p.token, p.enabled, "global")
    end
    store.oast_providers.each do |p|
      out << ProviderConfig.new(p.id.to_s, p.name, p.kind, p.host, p.token, p.enabled?, "project")
    end
    out
  end
end
