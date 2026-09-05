require "../spec_helper"

# `get_repeater_context{filter}` — the TUI's own sub-tab filter language, answered headlessly
# over stored rows. The point of the shared grammar is that ONE session cannot be described
# differently by the operator's `/` and an agent's `filter`, so the projections are pinned
# against each other here rather than only against literals.

private def tools(store)
  Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
end

private def call_json(store, name, args : String) : JSON::Any
  r = tools(store).call(name, JSON.parse(args))
  fail "#{name} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

private def names(store, args : String) : Array(String)
  call_json(store, "get_repeater_context", args)["sessions"].as_a.map { |s| s["name"]?.try(&.as_s) || "" }
end

private def seed(store) : Nil
  a = store.insert_repeater("https://api.test/v1", "GET /v1/users HTTP/1.1\r\nHost: api.test\r\n\r\n".to_slice,
    false, true, nil, 0)
  store.set_repeater_name(a, "users")
  store.set_repeater_tags(a, "idor auth")
  store.update_repeater_response(a, "HTTP/1.1 200 OK\r\n\r\n".to_slice, "{}".to_slice, nil, 12_i64)

  b = store.insert_repeater("https://shop.test/cart", "POST /cart HTTP/1.1\r\nHost: shop.test\r\n\r\n".to_slice,
    false, true, nil, 1)
  store.set_repeater_name(b, "cart")
  store.set_repeater_tags(b, "idor")
  store.update_repeater_response(b, "HTTP/1.1 403 Forbidden\r\n\r\n".to_slice, nil, nil, 9_i64)

  c = store.insert_repeater("https://shop.test/admin", "DELETE /admin HTTP/1.1\r\nHost: shop.test\r\n\r\n".to_slice,
    false, true, nil, 2)
  store.set_repeater_name(c, "admin")
  store.update_repeater_response(c, Bytes.empty, nil, "connection refused", 3_i64)

  d = store.insert_repeater("https://shop.test/new", "GET /new HTTP/1.1\r\nHost: shop.test\r\n\r\n".to_slice,
    false, true, nil, 3)
  store.set_repeater_name(d, "unsent")
end

describe "MCP get_repeater_context filter" do
  it "filters by tag" do
    with_store do |store|
      seed(store)
      names(store, %({"filter":"tag:idor"})).should eq(%w[users cart])
      names(store, %({"filter":"-tag:idor"})).should eq(%w[admin unsent])
    end
  end

  it "filters by host and method" do
    with_store do |store|
      seed(store)
      names(store, %({"filter":"host:shop.test"})).should eq(%w[cart admin unsent])
      names(store, %({"filter":"method:get"})).should eq(%w[users unsent])
      names(store, %({"filter":"host:shop.test method:get"})).should eq(%w[unsent])
    end
  end

  it "filters by the last send's status, by prefix" do
    with_store do |store|
      seed(store)
      names(store, %({"filter":"status:200"})).should eq(%w[users])
      names(store, %({"filter":"status:4"})).should eq(%w[cart])
      names(store, %({"filter":"status:error"})).should eq(%w[admin])
      names(store, %({"filter":"status:unsent"})).should eq(%w[unsent])
    end
  end

  it "ANDs filter with query rather than replacing it" do
    with_store do |store|
      seed(store)
      names(store, %({"query":"shop.test","filter":"tag:idor"})).should eq(%w[cart])
    end
  end

  it "matches nothing — and says so — for a term no session has" do
    with_store do |store|
      seed(store)
      names(store, %({"filter":"tag:nosuchtag"})).should be_empty
    end
  end

  it "reports a filter that produced no usable term instead of quietly returning everything" do
    with_store do |store|
      seed(store)
      got = call_json(store, "get_repeater_context", %({"filter":"()"}))
      got["sessions"].as_a.size.should eq(4)
      got["filter_ignored"].as_bool.should be_true
      got["filter_ignored_note"].as_s.should contain("narrowed nothing")
    end
  end

  it "agrees with the projection the TUI's own strip filters on" do
    with_store do |store|
      seed(store)
      rows = store.repeaters_mcp
      f = Gori::Repeater::SubtabFilter.parse("host:shop.test -tag:idor")
      expected = rows.select { |r| f.matches?(Gori::Repeater::SubtabFilter::Subject.from_row(r)) }.map(&.name)
      names(store, %({"filter":"host:shop.test -tag:idor"})).should eq(expected)
    end
  end

  it "survives a session whose request bytes are not valid UTF-8" do
    with_store do |store|
      seed(store)
      bad = store.insert_repeater("https://bin.test", Bytes[0x47, 0x45, 0x54, 0x20, 0xff, 0x0d, 0x0a, 0x0d, 0x0a],
        false, true, nil, 9)
      store.set_repeater_name(bad, "binary")
      names(store, %({"filter":"host:bin"})).should eq(%w[binary])
    end
  end
end
