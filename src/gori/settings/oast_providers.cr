require "json"

# OAST PROVIDERS section (settings:oast providers → global scope): user-defined OAST
# providers, reusable across every project. See settings.cr for the module-level overview
# and the load/save/serialize orchestration.
module Gori::Settings
  # A GLOBAL OAST provider (settings.json "oast_providers"), reusable across every project.
  # `kind` is the Oast::ProviderKind label. Project-scoped providers live in the project DB
  # (Store::OastProviderRecord / oast_providers table). `id` is a random hex token assigned
  # on creation. Mirrors ScanRule (the same global/project split for Probe custom rules).
  record OastProvider,
    id : String,
    name : String,
    kind : String,
    host : String,
    token : String?,
    enabled : Bool
  class_property oast_providers : Array(OastProvider) = [] of OastProvider

  # Tolerant global-provider parse: a non-array (or absent) node keeps the current value;
  # entries missing id/name/kind/host are dropped. Mirrors parse_scan_rules' robustness.
  private def self.parse_oast_providers(node : JSON::Any?) : Array(OastProvider)
    arr = node.try(&.as_a?)
    return oast_providers unless arr
    out = [] of OastProvider
    arr.each do |e|
      next unless o = e.as_h?
      id = o["id"]?.try(&.as_s?)
      name = o["name"]?.try(&.as_s?)
      kind = o["kind"]?.try(&.as_s?)
      host = o["host"]?.try(&.as_s?)
      next if id.nil? || id.empty? || name.nil? || name.empty? || kind.nil? || kind.empty? || host.nil? || host.empty?
      token = o["token"]?.try(&.as_s?)
      enabled = o["enabled"]?.try(&.as_bool?)
      out << OastProvider.new(id, name, kind, host, token, enabled.nil? ? true : enabled)
    end
    out
  end

  # --- global provider library CRUD (settings:oast providers → global scope) ---------------
  # Each mutation rewrites the array and persists via save (atomic + 3-way merge). add returns
  # the new provider's generated id so the caller can select it.
  def self.add_oast_provider(name : String, kind : String, host : String, token : String?, enabled : Bool = true) : String
    id = Random::Secure.hex(4)
    self.oast_providers = oast_providers + [OastProvider.new(id, name, kind, host, token, enabled)]
    save
    id
  end

  def self.update_oast_provider(id : String, name : String, kind : String, host : String, token : String?) : Nil
    self.oast_providers = oast_providers.map do |p|
      p.id == id ? OastProvider.new(id, name, kind, host, token, p.enabled) : p
    end
    save
  end

  def self.set_oast_provider_enabled(id : String, enabled : Bool) : Nil
    self.oast_providers = oast_providers.map { |p| p.id == id ? p.copy_with(enabled: enabled) : p }
    save
  end

  def self.delete_oast_provider(id : String) : Nil
    self.oast_providers = oast_providers.reject { |p| p.id == id }
    save
  end

  # Omit when empty so an untouched install never writes "oast_providers": [].
  private def self.serialize_oast_providers(j : JSON::Builder) : Nil
    unless oast_providers.empty?
      j.field "oast_providers" do
        j.array do
          oast_providers.each do |p|
            j.object do
              j.field "id", p.id
              j.field "name", p.name
              j.field "kind", p.kind
              j.field "host", p.host
              j.field "token", p.token if p.token
              j.field "enabled", p.enabled
            end
          end
        end
      end
    end
  end
end
