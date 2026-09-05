require "../spec_helper"

# A field QL does not implement free-texts its WHOLE token (`ql.cr`'s `field_cond` else-branch,
# on purpose), so `list_history{query:"methd:GET"}` ran a literal substring search over
# method/host/target and came back `[]` with `isError:false`. On this transport the caller is a
# model with no screen: "this project has no such traffic" and "you spelled `method` wrong" were
# the same answer, and `strict:true` did not separate them either — an unknown field COMPILES, so
# `QL.analyze` files it under `applied`, which is the half `strict` never reports.
#
# `gori run history/sitemap/probe` has refused this since #884; so do the MCP tools that SAVE a
# query (`create_view`, `create_color_rule`). These are the read tools that did not.

private def call_tools(store, name : String, args : Hash(String, JSON::Any)) : Gori::MCP::Tools::Result
  tools_for(store).call(name, JSON::Any.new(args))
end

private def q(query : String, **rest) : Hash(String, JSON::Any)
  h = {"query" => JSON::Any.new(query)} of String => JSON::Any
  rest.each { |k, v| h[k.to_s] = JSON::Any.new(v) }
  h
end

describe "MCP query tools: an unknown QL field" do
  it "is refused rather than searched as text, naming the field and the spelling meant" do
    with_store do |store|
      r = call_tools(store, "list_history", q("methd:GET"))
      r.is_error.should be_true
      r.error_code.should eq("QUERY_SYNTAX")
      r.field.should eq("query")
      r.text.should contain("methd:")
      r.text.should contain("did you mean `method:`")
    end
  end

  it "echoes the operator the term was written with" do
    with_store do |store|
      call_tools(store, "list_history", q("hsot~acme")).text.should contain("`hsot~`")
    end
  end

  it "lists the fields when nothing is close enough to suggest" do
    with_store do |store|
      t = call_tools(store, "list_history", q("xyzzy:1")).text
      t.should contain("QL has no such field")
      t.should contain("status")
    end
  end

  it "is refused by every read tool that takes a QL query, not only list_history" do
    with_store do |store|
      {
        "list_history"    => q("methd:GET"),
        "list_sitemap"    => q("methd:GET"),
        "probe_scan"      => q("methd:GET"),
        "diff_projects"   => q("methd:GET").tap { |h| h["from"] = JSON::Any.new("nope") },
        "authorize_start" => q("methd:GET"),
      }.each do |name, args|
        r = call_tools(store, name, args)
        r.is_error.should be_true
        r.error_code.should eq("QUERY_SYNTAX"), "#{name} answered #{r.error_code}: #{r.text}"
      end
    end
  end

  it "keeps `strict` meaning what it means — a dropped term, not an unknown field" do
    with_store do |store|
      # `status:zzz` compiles to nothing and is DROPPED (broadens); that is strict's half.
      call_tools(store, "list_history", q("host:a status:zzz")).is_error.should be_false
      call_tools(store, "list_history", q("host:a status:zzz", strict: true)).is_error.should be_true
    end
  end

  it "runs the query as literal text under lenient:true" do
    with_store do |store|
      r = call_tools(store, "list_history", q("methd:GET", lenient: true))
      r.is_error.should be_false
      r.text.should eq("[]")
    end
  end

  it "does not refuse a token that names no field — a pasted URL, an authority, a bare word" do
    with_store do |store|
      ["http://acme.test/x", "acme.test:8443", "login", "12:34"].each do |query|
        r = call_tools(store, "list_history", q(query))
        r.is_error.should be_false, "#{query} was refused: #{r.text}"
      end
    end
  end

  it "accepts every field QL implements, including the ones only its aliases spell" do
    with_store do |store|
      ["host:a", "resp.body:a", "res.body:a", "source:proxy", "req.size:>1", "dur:>1"].each do |query|
        r = call_tools(store, "list_history", q(query))
        r.is_error.should be_false, "#{query} was refused: #{r.text}"
      end
    end
  end
end
