require "../../spec_helper"
require "json"

# `gori run views` — the printed shapes. The commands themselves end in `abort`/`exit` and
# cannot be exercised from a spec, so what is pinned here is what an operator (or a script
# parsing `--format=json`) actually reads. Same split as spec/cli/run/colormarker_spec.cr.
private def view(name = "acme errors", query = "status:>=500", scope = "project", id = "1")
  Gori::SavedViews::View.new(id, name, query, scope)
end

private def json_for(v : Gori::SavedViews::View, active : Gori::SavedViews::View? = nil) : JSON::Any
  JSON.parse(JSON.build { |j| Gori::CLI::Run.view_json(j, v, active) })
end

describe "gori run views — text rows" do
  it "carries the scope letter, because that is half the view's address" do
    # The two stores are addressed independently and a name may exist in both, so the name
    # alone does not say which view the next command would touch. Same G/P spelling
    # `gori run colormarker` prints.
    Gori::CLI::Run.view_row(view, nil, 11).should eq("  P acme errors  status:>=500")
    Gori::CLI::Run.view_row(view(scope: "global"), nil, 11).should eq("  G acme errors  status:>=500")
    Gori::CLI::Run.view_row(Gori::SavedViews.all_view, nil, 11)
      .should start_with("● · All")
  end

  it "marks the view this project is looking through" do
    v = view
    Gori::CLI::Run.view_row(v, v, 11).should start_with("● P")
    Gori::CLI::Run.view_row(view(name: "other", id: "2"), v, 11).should start_with("  P")
  end

  it "marks All when nothing is narrowing, rather than marking no row at all" do
    # "no view" and "the All view" are the same state; a listing where nothing is marked would
    # read as a bug.
    Gori::CLI::Run.view_row(Gori::SavedViews.all_view, nil, 5).should start_with("●")
  end

  it "names an empty query rather than printing a blank tail" do
    Gori::CLI::Run.view_row(Gori::SavedViews.all_view, nil, 5)
      .should end_with("(everything — no source term)")
  end

  it "aligns the query column so the queries line up down the list" do
    a = Gori::CLI::Run.view_row(view(name: "a", query: "host:a"), nil, 12)
    b = Gori::CLI::Run.view_row(view(name: "a longer one", query: "host:b"), nil, 12)
    a.index("host:a").should eq(b.index("host:b"))
  end
end

describe "gori run views --format=json" do
  it "emits the name, query, scope and key a script needs to address a view again" do
    o = json_for(view).as_h
    o["name"].as_s.should eq("acme errors")
    o["query"].as_s.should eq("status:>=500")
    o["scope"].as_s.should eq("project")
    # The key disambiguates the two stores for a script that keeps a pointer, the same way
    # the project's own `history_view` setting does.
    o["key"].as_s.should eq("p_1")
    o["active"].as_bool.should be_false
  end

  it "reports the active view, and reports All as active when none is set" do
    v = view
    json_for(v, v).as_h["active"].as_bool.should be_true
    json_for(Gori::SavedViews.all_view, nil).as_h["active"].as_bool.should be_true
    json_for(v, nil).as_h["active"].as_bool.should be_false
  end
end
