require "./builder"

module Gori
  module Import
    module Urls
      def self.parse_file(path : String) : ParseResult
        now = Time.utc.to_unix * 1_000_000
        pairs = [] of Builder::FlowPair
        skipped = 0
        File.each_line(path) do |line|
          url = line.strip
          next if url.empty?
          next if url.starts_with?('#')
          # Skip (don't abort on) a line Builder can't turn into an http(s) request —
          # a non-http scheme (ftp://, mailto:, ws://, tel:) or a host-less URL raises.
          # These are common in scraped/exported lists; one used to discard the whole file.
          begin
            pairs << Builder.pending_request(now, url)
          rescue
            skipped += 1
          end
        end
        ParseResult.new(pairs, skipped)
      end
    end
  end
end
