require "uri"
require "./types"

module Gori::Oast
  # One-click public providers for the "quick add" affordance. interactsh has several
  # interchangeable public servers; the others have a canonical public host.
  module Presets
    record Preset, kind : ProviderKind, name : String, host : String, token : String? = nil

    INTERACTSH_SERVERS = %w(
      https://oast.pro
      https://oast.live
      https://oast.site
      https://oast.fun
      https://oast.me
    )

    def self.all : Array(Preset)
      list = [] of Preset
      INTERACTSH_SERVERS.each do |u|
        host = URI.parse(u).host || u
        list << Preset.new(ProviderKind::Interactsh, "Public Interactsh (#{host})", u)
      end
      list << Preset.new(ProviderKind::Boast, "Public BOAST (odiss.eu)", "https://odiss.eu:2096/events")
      list << Preset.new(ProviderKind::WebhookSite, "Public webhook.site", "https://webhook.site")
      list << Preset.new(ProviderKind::Postbin, "Public PostBin", "https://www.postb.in")
      list
    end
  end
end
