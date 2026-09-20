require "../spec_helper"

include Gori::Tui

# The project picker's search and its row labels. The picker owns a live Termisu and cannot
# be built in a spec, so both rules live in class methods — the same shape `meta_segments`
# and `ProjectMarks` use for the delete set.
#
# What is being pinned: the picker used to look at the display NAME and nothing else, while
# `gori run project list --query` and MCP `list_projects{query}` narrow on the name, the
# directory slug, the short id AND the bound workspace path. Display names are deliberately
# not unique (two checkouts with the same basename share one), so the slug was both the only
# way to tell such a pair apart and the one spelling the picker would not accept.

private def entry(name : String, slug : String, id : String? = nil, workspace : String? = nil)
  Gori::ProjectRegistry::Entry.new(
    Gori::Project.new(name, "/p/#{slug}/gori.db"), id, slug, workspace)
end

# What `create_for_workspace` produces for two checkouts that share a basename: distinct
# slugs, ONE display name, and the workspace path that actually tells them apart.
private def twin_registry
  [
    entry("api", "api", "7d99e350", "/w/billing/api"),
    entry("Acme API", "acme-api", "84bd1a35"),
    entry("api", "api-2", "9fd76572", "/w/payments/api"),
  ]
end

describe "ProjectPicker.narrow" do
  it "keeps every project for a query that narrows nothing" do
    entries = twin_registry
    ProjectPicker.narrow(entries, "").should eq(entries)
    # Folded through `ProjectRegistry.needle`, so blank means blank on this surface too.
    ProjectPicker.narrow(entries, "   ").should eq(entries)
  end

  it "still fuzzy-ranks the display name, best first" do
    # The common gesture, unchanged: "aa" is a subsequence of "Acme API" and of neither
    # "api", and an exact name outranks a scattered match.
    ProjectPicker.narrow(twin_registry, "aa").map(&.slug).should eq(["acme-api"])
    ProjectPicker.narrow(twin_registry, "api").map(&.slug).first(2).should eq(["api", "api-2"])
  end

  it "finds a project by the workspace it is bound to" do
    # Zero matches before: the picker never looked at the workspace path, which for two
    # projects sharing a display name is the only thing that names the right one.
    ProjectPicker.narrow(twin_registry, "payments").map(&.slug).should eq(["api-2"])
    ProjectPicker.narrow(twin_registry, "billing").map(&.slug).should eq(["api"])
  end

  it "finds a project by its short id or its directory slug" do
    ProjectPicker.narrow(twin_registry, "84bd").map(&.slug).should eq(["acme-api"])
    ProjectPicker.narrow(twin_registry, "api-2").map(&.slug).should eq(["api-2"])
  end

  it "ranks every fuzzy name hit above the other three spellings" do
    # A query that hits one project's NAME and another's workspace: the name match leads,
    # because that is what the operator almost always typed.
    entries = [
      entry("billing", "billing", "aaaa1111"),
      entry("payments", "payments", "bbbb2222", "/w/billing/api"),
    ]
    ProjectPicker.narrow(entries, "billing").map(&.slug).should eq(["billing", "payments"])
  end

  it "lists a project once when several spellings match it" do
    # A name-substring is also a name-subsequence, so the fuzzy pass claims it and the
    # substring pass must not add it again.
    entries = [entry("api", "api", "aaaa1111", "/w/api")]
    ProjectPicker.narrow(entries, "api").size.should eq(1)
  end
end

describe "ProjectPicker.row_labels" do
  it "adds the directory slug only to the names another project shares" do
    labels = ProjectPicker.row_labels(twin_registry)
    labels["/p/api"].should eq("api  ·  api")
    labels["/p/api-2"].should eq("api  ·  api-2")
    # A unique name stays exactly as it was: a slug beside every row is noise, and for a
    # hand-created project the slug is just the name again.
    labels["/p/acme-api"].should eq("Acme API")
  end

  it "judges the collision case-insensitively, as #find resolves it" do
    labels = ProjectPicker.row_labels([entry("API", "api"), entry("api", "api-2")])
    labels.values.each(&.should(contain("·")))
  end

  it "labels every project in a registry with no collisions at all" do
    labels = ProjectPicker.row_labels([entry("alpha", "alpha"), entry("beta", "beta")])
    labels.should eq({"/p/alpha" => "alpha", "/p/beta" => "beta"})
  end
end
