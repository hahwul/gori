require "./spec_helper"

# Keep app-owned socket and HTTP-client constructors behind the reviewed routing seams.
# Comments may name the APIs; executable lines may not grow a second dial policy.
describe "egress seams" do
  it "keeps sockets and HTTP clients in their single owners" do
    root = File.expand_path(File.join(__DIR__, ".."))
    offenders = [] of String
    Dir.glob(File.join(root, "src", "gori", "**", "*.cr")).sort.each do |path|
      relative = Path[path].relative_to(root).to_s
      File.read_lines(path).each_with_index do |line, index|
        next if line.lstrip.starts_with?('#')
        if line.matches?(/\b(?:TCPSocket|UDPSocket)\.new|\bSocket\.(?:tcp|udp)/) &&
           relative != "src/gori/proxy/upstream.cr"
          offenders << "#{relative}:#{index + 1}: direct socket: #{line.strip}"
        end
        if line.includes?("HTTP::Client.new") && relative != "src/gori/http_transport.cr"
          offenders << "#{relative}:#{index + 1}: direct HTTP client: #{line.strip}"
        end
      end
    end
    fail("app egress bypasses its routing seam:\n#{offenders.join("\n")}") unless offenders.empty?
  end
end
