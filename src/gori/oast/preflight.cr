require "uri"
require "./http"
require "./presets"
require "../http_transport"

module Gori::Oast
  # Reachability preflight for the built-in public providers (#1020).
  #
  # Registration talks to a third-party server over HTTPS, so it can fail four ways that look
  # identical from a single failed `oast listen`: the name does not resolve, the port is
  # filtered, the certificate chain is rejected by this machine's trust store, or the provider
  # is simply down. Which one it is decides the remedy — a resolver, a firewall rule, an
  # SSL_CERT_FILE bundle, or another preset — so the operator needs the STAGE, not a verdict.
  #
  # The probe is deliberately the preset host's origin root, not its API: this answers "can
  # this machine complete an HTTPS exchange with that host", and any HTTP status is a yes.
  # Asking `/register` instead would mint third-party state as a side effect of a diagnostic.
  module Preflight
    # `ok` and `stage` are two facts, not one: a reachable preset carries the status it
    # answered with, and a failed one carries the stage plus the layer's own sentence — the
    # same text `oast listen` would have printed, so the two surfaces never disagree.
    record Result,
      preset : Presets::Preset,
      ok : Bool,
      stage : String,
      detail : String,
      elapsed : Time::Span do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "kind", preset.kind.label
          json.field "name", preset.name
          json.field "host", preset.host
          json.field "ok", ok
          json.field "stage", stage
          json.field "detail", detail
          json.field "ms", elapsed.total_milliseconds.round(1)
        end
      end
    end

    # One preset, one exchange. Never raises: a preflight that blew up would be one more
    # failure the operator has to classify by hand.
    def self.check(preset : Presets::Preset, http : Http = HttpClient.new) : Result
      started = Time.instant
      begin
        resp = http.request("GET", probe_url(preset))
        Result.new(preset, true, "ok", "HTTP #{resp.status}", Time.instant - started)
      rescue ex : Gori::HttpTransport::Error
        # The dial stage the transport already identified. Its message carries the remedy
        # (SSL_CERT_FILE for a rejected chain, and pointedly NOT for anything else).
        Result.new(preset, false, stage_for(ex.kind), message_of(ex), Time.instant - started)
      rescue ex
        Result.new(preset, false, "exchange", message_of(ex), Time.instant - started)
      end
    end

    # Every preset at once, answered in the order given. Concurrent because a restricted
    # network fails these by TIMEOUT, and eight serial 20s timeouts is not a diagnostic
    # anyone waits for. Each fiber dials its own client; a caller passing a shared fake `http`
    # is responsible for it being safe to share.
    def self.check_all(presets : Array(Presets::Preset) = Presets.all,
                       http : Http? = nil) : Array(Result)
      return [] of Result if presets.empty?
      slots = Array(Result?).new(presets.size, nil)
      done = Channel(Nil).new(presets.size)
      presets.each_with_index do |preset, i|
        spawn do
          slots[i] = check(preset, http || HttpClient.new)
        ensure
          # In the `ensure` so a fiber that dies anyway still releases the wait — otherwise a
          # single unexpected raise hangs the command forever instead of losing one row.
          done.send(nil)
        end
      end
      presets.size.times { done.receive }
      slots.compact
    end

    # What to hit. The origin root of the preset's URL, so a provider whose preset carries a
    # path (BOAST's `/events`) is probed as a HOST rather than as an endpoint whose 404 or
    # 401 would need interpreting.
    def self.probe_url(preset : Presets::Preset) : String
      uri = URI.parse(preset.host)
      host = uri.host
      return preset.host unless host
      scheme = uri.scheme.presence || "https"
      port = uri.port
      authority = host.includes?(':') ? "[#{host}]" : host
      authority = "#{authority}:#{port}" if port
      "#{scheme}://#{authority}/"
    rescue
      preset.host
    end

    # The dialer's verdict as a short token for the report. nil means the failure happened
    # past the dial, which is a reachable host by any reading.
    private def self.stage_for(kind : Proxy::Upstream::DialErrorKind?) : String
      case kind
      # A transport failure the dialer could not attribute to a stage — a malformed provider
      # URL, or a raise past the dial itself. NOT "exchange": by this file's own definition that
      # means the host was reached, which is the opposite of what happened.
      when Nil          then "dial"
      when .dns?        then "dns"
      when .connect?    then "connect"
      when .proxy?      then "proxy"
      when .tls_verify? then "tls-verify"
      when .tls?        then "tls"
      when .timeout?    then "timeout"
      else                   "error"
      end
    end

    private def self.message_of(ex : Exception) : String
      (ex.message.presence || ex.class.name).gsub(/\s+/, " ").strip
    end
  end
end
