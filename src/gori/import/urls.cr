require "./builder"

module Gori
  module Import
    module Urls
      def self.parse_file(path : String) : Array(Builder::FlowPair)
        now = Time.utc.to_unix * 1_000_000
        pairs = [] of Builder::FlowPair
        File.each_line(path) do |line|
          url = line.strip
          next if url.empty?
          next if url.starts_with?('#')
          pairs << Builder.pending_request(now, url)
        end
        pairs
      end
    end
  end
end