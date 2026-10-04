require "../spec_helper"

# #1371 / #1372: a Sitemap root is an ORIGIN, so every Runner verb that turns a Sitemap row into
# a flow has to look it up on that row's scheme and port — `sitemap_flow_id`, the one home — and
# Discover must start where the row's traffic went rather than guess `https://<host>`.
#
# `Runner.new` owns a terminal and appears nowhere under spec/, so this reads the Runner slices
# with comments stripped, the convention issues_primary_flow_spec established. The inventory is
# DERIVED (every slice that reads the Sitemap view's endpoint), with a floor, so a new verb
# joins the check without anyone listing it.
private def runner_slices : Hash(String, String)
  dir = File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner")
  glob_files(dir, "*.cr").to_h do |path|
    {File.basename(path), File.read(path).lines.reject(&.lstrip.starts_with?('#')).join('\n')}
  end
end

describe "Sitemap sends resolve on the row's origin" do
  it "looks every Sitemap endpoint up through sitemap_flow_id" do
    slices = runner_slices
    readers = slices.select { |_, code| code.includes?("selected_endpoint") || code.includes?("target_endpoints") }
    readers.size.should be >= 5 # authorize, comparer, discover, sequencer, sitemap
    readers.each { |file, code| code.should contain("sitemap_flow_id(ep)"), file: file }
    # The store lookup itself appears ONCE, in the helper, which passes the origin on.
    calls = slices.sum { |_, code| code.scan(/representative_flow_id\(/).size }
    calls.should eq(1)
    helper = slices["sitemap.cr"][/def sitemap_flow_id.*?\n  end/m]?.should_not be_nil
    helper.should contain("representative_flow_id(ep[:host], ep[:method], ep[:target], o.try(&.scheme), o.try(&.port))")
  end

  it "starts a host row's Discover at the row's origin and never guesses https" do
    code = runner_slices["discover.cr"]
    code.should contain("ep[:origin]")
    code.should_not contain(%("https://\#{ep[:host]}"))
  end
end
