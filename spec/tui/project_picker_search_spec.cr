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

describe "ProjectPicker.row_discriminators" do
  it "marks only the names another project shares, and prefers the workspace" do
    d = ProjectPicker.row_discriminators(twin_registry)
    # `create_for_workspace` takes the NAME from the workspace basename, so for the pair this
    # exists for the basename is the name and the parent is the whole of the difference —
    # "billing" vs "payments" reads at a glance where "api" vs "api-2" does not.
    d["/p/api"].should eq("billing")
    d["/p/api-2"].should eq("payments")
    # A unique name gets nothing beside it: a discriminator on every row is noise, and for a
    # hand-created project the slug is just the name again.
    d.has_key?("/p/acme-api").should be_false
  end

  it "falls back to the directory slug when no workspace is bound" do
    d = ProjectPicker.row_discriminators([entry("api", "api"), entry("api", "api-2")])
    d["/p/api"].should eq("api")
    d["/p/api-2"].should eq("api-2")
  end

  it "judges the collision case-insensitively, as #find resolves it" do
    d = ProjectPicker.row_discriminators([entry("API", "api"), entry("api", "api-2")])
    d.size.should eq(2)
  end

  it "uses the workspace basename when it is not simply the name again" do
    # A renamed project keeps its binding, so the basename can be the useful half.
    d = ProjectPicker.row_discriminators([
      entry("staging", "staging", "aaaa1111", "/w/acme-web"),
      entry("staging", "staging-2", "bbbb2222", "/w/acme-mobile"),
    ])
    d["/p/staging"].should eq("acme-web")
    d["/p/staging-2"].should eq("acme-mobile")
  end
end

describe "ProjectPicker.fit_label" do
  it "leaves a unique name untouched at any width" do
    ProjectPicker.fit_label("acme", nil, 4).should eq("acme")
  end

  it "shortens the NAME, never the part that disambiguates" do
    # `Screen#text` ellipsizes from the right, so a joined label handed to it whole loses
    # exactly the discriminator — two same-named rows rendering identically again, which is
    # the failure this whole pair exists to prevent.
    tight = ProjectPicker.fit_label("payments-api", "billing", 16)
    tight.should end_with(" · billing")
    Screen.display_width(tight).should be <= 16
  end

  it "keeps the discriminator alone when the name cannot be elided into" do
    ProjectPicker.fit_label("payments-api", "billing", 10).should eq("billing")
  end

  it "joins without shortening when it already fits" do
    ProjectPicker.fit_label("api", "billing", 40).should eq("api · billing")
    ProjectPicker.labelled("api", "billing").should eq("api · billing")
    ProjectPicker.labelled("api", nil).should eq("api")
  end
end

describe "ProjectPicker.delete_confirm_body with disambiguated names" do
  it "still names both halves of a same-named pair rather than falling back to a count" do
    # The confirm drops to "Delete 2 projects?" once the names run past NAMED_DELETE_WIDTH,
    # so a discriminator that is too long costs the irreversible confirm the very names it
    # was added to disambiguate. `billing`/`payments` beat `payments-api`/`payments-api-2`
    # precisely because they are short.
    names = twin_registry.select { |e| e.project.name == "api" }.map do |e|
      ProjectPicker.labelled(e.project.name, ProjectPicker.discriminator(e))
    end
    body = ProjectPicker.delete_confirm_body(names, 0, 0)
    body.should contain("api · billing")
    body.should contain("api · payments")
    body.should_not contain("Delete 2 projects?")
  end
end
