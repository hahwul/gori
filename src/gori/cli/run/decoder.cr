# `gori run decoder` — run a value through the Decoder engine's converter chain
# (the same engine behind the TUI Decoder tab): base64/hex/url/gzip/jwt/… encode,
# decode, hash and transform, composed left-to-right. Exposes the whole catalog to
# scripts, which previously only had the single-purpose `gori run jwt`.
module Gori
  module CLI
    module Run
      private def self.cmd_decoder(args : Array(String)) : Nil
        if args.first? == "list"
          cmd_decoder_list(args[1..])
          return
        end

        output_mode : Decoder::RenderAs? = nil
        input_flag : String? = nil
        format = :text
        positional = [] of String

        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run decoder <chain> [input] [options]\n\n" \
                     "Run INPUT through a left-to-right converter CHAIN (separators: > | ,).\n" \
                     "INPUT comes from the 2nd positional arg, --input, or STDIN (verbatim).\n\n" \
                     "Examples:\n" \
                     "  gori run decoder base64-decode SGVsbG8=\n" \
                     "  gori run decoder 'url-decode > base64-decode' %53%47%56%73%62%47%38%3D\n" \
                     "  printf hello | gori run decoder sha256\n" \
                     "  gori run decoder base64-decode --output hex <base64-of-binary>\n\n" \
                     "Run 'gori run decoder list' for every converter name."
          p.on("--input=STR", "Value to convert (else 2nd positional arg, else STDIN)") { |v| input_flag = v }
          p.on("-oMODE", "--output=MODE", "Render final bytes: auto (default) | text | base64 | hex") { |v| output_mode = parse_render_mode(v) }
          p.on("--format=FMT", "Output: text (default) | json (per-step detail)") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |rest, _| positional = rest }
          p.invalid_option { |f| abort "gori run decoder: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run decoder: missing value for #{f}" }
        end
        parser.parse(args)

        abort "gori run decoder: missing <chain> (e.g. 'base64-decode'; see 'gori run decoder list')" if positional.empty?
        abort "gori run decoder: too many arguments (expected <chain> [input])" if positional.size > 2
        chain = positional[0]

        input_str = input_flag || positional[1]?
        input_str ||= STDIN.gets_to_end unless STDIN.tty?
        abort "gori run decoder: no input (pass it as an argument, --input, or via STDIN)" if input_str.nil?

        result = Decoder.run(Decoder.shared_registry, input_str.to_slice, chain)

        if format == :json
          puts decoder_json(result, output_mode)
        else
          if final_bytes = result.output
            rendered, _ = Decoder.display(final_bytes, output_mode)
            STDOUT.puts rendered
          end
          unless result.ok?
            report_convert_failure(result)
            exit 1
          end
        end
      end

      # STDERR line for the first non-Ok step, so a failing chain is diagnosable in
      # the text view (the JSON view carries the same via `failed_at` + step state).
      private def self.report_convert_failure(result : Decoder::ChainResult) : Nil
        i = result.failed_at
        return unless i
        s = result.steps[i]
        reason = s.state.unknown? ? "is not a known converter (see 'gori run decoder list')" : "failed"
        STDERR.puts "gori run decoder: step ##{i + 1} '#{s.token}' #{reason}#{s.error ? ": #{s.error}" : ""}"
      end

      private def self.decoder_json(result : Decoder::ChainResult, mode : Decoder::RenderAs?) : String
        JSON.build do |j|
          j.object do
            j.field "ok", result.ok?
            j.field "steps" do
              j.array do
                result.steps.each do |s|
                  j.object do
                    j.field "token", s.token
                    j.field "name", s.name
                    j.field "state", s.state.to_s.downcase
                    if o = s.output
                      # Intermediate steps render as-is (auto); only the FINAL output
                      # honors an explicit --output mode.
                      rendered, render = Decoder.display(o, nil)
                      j.field "render", render.to_s.downcase
                      j.field "output", rendered
                    end
                    j.field "error", s.error if s.error
                  end
                end
              end
            end
            if final_bytes = result.output
              rendered, render = Decoder.display(final_bytes, mode)
              j.field "render", render.to_s.downcase
              j.field "output", rendered
            end
            j.field "failed_at", result.failed_at.try(&.+(1))
          end
        end
      end

      private def self.parse_render_mode(v : String) : Decoder::RenderAs?
        case v.downcase
        when "auto"   then nil
        when "text"   then Decoder::RenderAs::Text
        when "base64" then Decoder::RenderAs::Base64
        when "hex"    then Decoder::RenderAs::Hex
        else               abort "gori run decoder: invalid --output '#{v}' (auto|text|base64|hex)"
        end
      end

      private def self.cmd_decoder_list(args : Array(String)) : Nil
        format = :text
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run decoder list [options]\n\nList every converter (name, category, direction)."
          p.on("--format=FMT", "Output: text (default) | json") { |v| format = parse_format(v, [:text, :json]) }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.invalid_option { |f| abort "gori run decoder list: unknown option: #{f}\n#{p}" }
        end
        parser.parse(args)

        registry = Decoder.shared_registry
        if format == :json
          puts(JSON.build do |j|
            j.array do
              registry.each do |c|
                j.object do
                  j.field "name", c.name
                  j.field "aliases", c.aliases
                  j.field "category", c.category.label
                  j.field "direction", c.direction.to_s.downcase
                  j.field "description", c.description
                end
              end
            end
          end)
        else
          registry.each do |c|
            puts "#{c.name.ljust(22)}  #{c.category.label.ljust(11)}  #{c.direction.to_s.downcase.ljust(9)}  #{c.description}"
          end
        end
      end
    end
  end
end
