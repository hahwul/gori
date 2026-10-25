require "../../spec_helper"

# `history_discover` narrows multi-origin marks to one origin. It grouped by HOST, so marks on
# h:8080 and h:9090 merged and the first service was seeded with the other's paths. The Runner
# owns a terminal, so this pins the grouping in the source.
describe "Runner#history_discover" do
  it "groups marked flows by origin, not by host" do
    src = File.read(File.join(__DIR__, "..", "..", "..", "src", "gori", "tui", "runner", "discover.cr"))
    src.should contain("hosts = parsed.map { |(_, p)| Discover::Url.origin(p) }.uniq!")
    src.should_not contain("p.host == keep[1].host")
  end

  it "names two ports on one host as two origins" do
    a = Gori::Discover::Url.parse("http://h.test:8080/a").not_nil!
    b = Gori::Discover::Url.parse("http://h.test:9090/b").not_nil!
    Gori::Discover::Url.origin(a).should_not eq(Gori::Discover::Url.origin(b))
  end
end
