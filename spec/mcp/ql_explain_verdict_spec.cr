require "../spec_helper"

# `ql_explain` exists to answer, without running anything, what `list_history` /
# `list_sitemap` / `probe_scan` will do with a query. It reported `QL.reject_empty?` under
# the name `matches_nothing`, which is that predicate's exact opposite: it is true when every
# term was DROPPED, so the filter is `QL::EMPTY` and the compiled SQL is the literal `1` —
# the whole capture. The same object carried `"sql":"1"` beside `"matches_nothing":true`.
# The never-match half was inverted too: an uncompilable `~` pattern compiles to `(0)` and
# came back `matches_nothing:false`.
#
# And neither condition said the thing that actually happens next — `ql_filter_or_error`
# turns BOTH into a QUERY_SYNTAX refusal, so a caller that explained first was told its query
# would run.

private def explain(store, query : String) : JSON::Any
  tools = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
  r = tools.call("ql_explain", JSON::Any.new({"query" => JSON::Any.new(query)}))
  fail "ql_explain errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

private def list_history_error(store, query : String) : String?
  tools = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
  r = tools.call("list_history", JSON::Any.new({"query" => JSON::Any.new(query)}))
  r.is_error ? r.text : nil
end

describe "MCP ql_explain verdict" do
  it "calls an all-terms-dropped query match-ALL, agreeing with its own compiled SQL" do
    with_store do |store|
      %w[host: (((].each do |q|
        j = explain(store, q)
        j["sql"].as_s.should eq("1")
        j["matches_everything"].as_bool.should be_true
      end
    end
  end

  it "does not call an all-terms-dropped query narrow" do
    with_store do |store|
      # The regression proper: the old field said this query matched NOTHING, so the reading
      # an agent takes from it ("loosen the filter") is the reverse of the fix.
      explain(store, "host:").as_h.has_key?("matches_nothing").should be_false
    end
  end

  it "predicts the QUERY_SYNTAX refusal the query tools answer with" do
    with_store do |store|
      {"host:", "(((", "body~[", "host:example.com body~["}.each do |q|
        list_history_error(store, q).should_not be_nil
        explain(store, q)["refused_by_query_tools"].as_bool.should be_true
      end
    end
  end

  it "leaves a query the tools do run unrefused" do
    with_store do |store|
      {"host:example.com", "status:>=500", "host:a status:zzz"}.each do |q|
        list_history_error(store, q).should be_nil
        j = explain(store, q)
        j["refused_by_query_tools"].as_bool.should be_false
        j["matches_everything"].as_bool.should be_false
      end
    end
  end

  it "warns that a match-all query is refused rather than broadened" do
    with_store do |store|
      w = explain(store, "host:")["warnings"].as_a.map(&.as_s)
      w.first.should contain("match-ALL")
      w.first.should contain("REFUSE")
      # The "dropped (broadens results)" line is still there — it names WHICH term went — but
      # it no longer stands alone saying the query would run with more rows.
      w.any?(&.starts_with?("dropped (broadens results):")).should be_true
    end
  end

  it "warns that an invalid regex is refused too" do
    with_store do |store|
      w = explain(store, "host:example.com body~[")["warnings"].as_a.map(&.as_s)
      w.find(&.includes?("invalid regex")).not_nil!.should contain("REFUSE")
    end
  end
end
