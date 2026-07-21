# `gori run oast` — listen for out-of-band callbacks (interactsh & friends);
# print the payload, then stream decrypted hits.
module Gori
  module CLI
    module Run
      # `gori run oast` — headless out-of-band listener (interactsh & friends). Store-free
      # and ad-hoc: register a payload, print it, then stream decrypted callbacks.
      private def self.cmd_oast(args : Array(String)) : Nil
        case sub = args.first?
        when "presets"           then oast_presets
        when "listen"            then oast_listen(args[1..])
        when nil, "-h", "--help" then oast_help
        else
          STDERR.puts "gori run oast: unknown subcommand '#{sub}'"
          oast_help
          exit 1
        end
      end

      private def self.oast_help : Nil
        puts <<-HELP
        Usage: gori run oast <subcommand>
          listen    Register an OAST payload and stream incoming callbacks
          presets   List the built-in public providers

        Run `gori run oast listen -h` for listen options.
        HELP
      end

      private def self.oast_presets : Nil
        Oast::Presets.all.each do |p|
          puts "#{p.kind.label.ljust(13)} #{p.name.ljust(34)} #{p.host}"
        end
      end

      private def self.oast_listen(args : Array(String)) : Nil
        provider = "interactsh"
        server : String? = nil
        token : String? = nil
        interval = 5
        json = false
        once = false
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run oast listen [options]"
          p.on("--provider=KIND", "interactsh (default) | custom-http | webhook.site | BOAST | postbin") { |v| provider = v }
          p.on("--server=URL", "Provider server/base URL (default: the provider's public preset)") { |v| server = v }
          p.on("--token=TOK", "Optional provider auth token") { |v| token = v }
          p.on("--interval=SEC", "Poll interval seconds (default 5)") { |v| interval = parse_count(v, "--interval") }
          p.on("--once", "Poll once and exit (no loop)") { once = true }
          p.on("--json", "Emit each callback as a JSON line (same shape as MCP)") { json = true }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
        end
        parser.parse(args)

        kind = Oast::ProviderKind.parse?(provider)
        unless kind
          STDERR.puts "gori run oast: unknown provider '#{provider}'"
          exit 1
        end
        host = server || Oast::Presets.all.find { |pr| pr.kind == kind }.try(&.host)
        unless host
          STDERR.puts "gori run oast: --server is required for #{kind.label}"
          exit 1
        end
        prov = Oast::Provider.build(kind, host, token)
        http = Oast::HttpClient.new
        session = begin
          prov.register(http)
        rescue ex
          STDERR.puts "gori run oast: register failed: #{ex.message}"
          exit 1
        end
        payload = prov.generate_payload(session)
        STDERR.puts "listening on #{host} (#{kind.label}) — payload:"
        puts payload
        STDERR.puts "waiting for callbacks (Ctrl-C to stop)…" unless once
        seen = Set(String).new
        loop do
          interactions = begin
            prov.poll(http, session)
          rescue ex
            STDERR.puts "poll error: #{ex.message}"
            [] of Oast::Interaction
          end
          interactions.each do |i|
            next if seen.includes?(i.unique_id)
            seen << i.unique_id
            if json
              puts Oast::Present.interaction(i, kind.label).to_json
            else
              puts "#{i.at.to_rfc3339}  #{i.protocol}\t#{i.method || "-"}\t#{i.source_ip || "-"}\t#{i.full_id}"
            end
            STDOUT.flush
          end
          break if once
          sleep interval.seconds
        end
        prov.deregister(http, session) if once
      end
    end
  end
end
