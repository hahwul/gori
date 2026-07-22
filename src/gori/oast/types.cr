module Gori
  # OAST (out-of-band application security testing): register a payload URL with an
  # interaction server (interactsh and friends), then observe the DNS/HTTP/SMTP callbacks
  # a target makes to it — the ground truth for blind SSRF, blind XXE, blind command
  # injection, JNDI, etc.
  #
  # This engine is Store- and TUI-free (mirrors Gori::Miner / Gori::Discover) so the one
  # implementation drives the TUI OAST tab, `gori run oast`, and the MCP oast_* tools. A
  # `Provider` abstraction with five implementations (interactsh + custom-http +
  # webhook.site + BOAST + postbin); a per-session interruptible `Poller`; normalized
  # `Interaction` records flowing over a `Channel(Event)`.
  module Oast
    # Which OAST backend a provider talks to. The label is the human/CLI token; `parse?`
    # is its inverse (nil on an unknown token — callers surface a Gori::Error).
    enum ProviderKind
      Interactsh
      CustomHttp
      WebhookSite
      Boast
      Postbin

      def label : String
        case self
        in .interactsh?   then "interactsh"
        in .custom_http?  then "custom-http"
        in .webhook_site? then "webhook.site"
        in .boast?        then "BOAST"
        in .postbin?      then "postbin"
        end
      end

      # Accepts the label OR the enum name (case-insensitive, - / _ / . all equivalent) so
      # both `--provider custom-http` and a stored "CustomHttp" token round-trip.
      def self.parse?(token : String) : ProviderKind?
        norm = token.downcase.gsub(/[-_.]/, "")
        case norm
        when "interactsh"  then Interactsh
        when "customhttp"  then CustomHttp
        when "webhooksite" then WebhookSite
        when "boast"       then Boast
        when "postbin"     then Postbin
        else                    nil
        end
      end
    end

    # One normalized received interaction, provider-agnostic. `unique_id` is the
    # provider-side dedup key (interactsh unique-id / webhook uuid / postbin req id / BOAST
    # event id / a content hash for custom-http). `full_id` is the destination sub-id shown
    # in the table (the hostname/path that was actually hit). `method` is nil for
    # non-HTTP protocols (DNS/SMTP).
    record Interaction,
      unique_id : String,
      protocol : String,
      method : String?,
      source_ip : String?,
      full_id : String,
      raw_request : String,
      raw_response : String?,
      at : Time

    # Engine → consumer events. A union of records (matches Miner/Fuzz so a Channel(Event)
    # carries them without boxing). `session_id` ties an event back to the Poller's session
    # (0 for an unpersisted/ad-hoc session).
    record CallbackEvent, session_id : Int64, interaction : Interaction
    record OastErrorEvent, session_id : Int64, message : String

    alias Event = CallbackEvent | OastErrorEvent
  end
end
