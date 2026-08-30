require "../spec_helper"

# `create_repeater`/`update_repeater` store `target` as the author wrote it (`wire_field`) and
# project it through `Env.mask_secrets` on the way OUT. `secrets_masked` / `secrets_masked_note`
# exist so that projection is never a SILENT substitution — but they were computed from the
# REQUEST bytes alone, so a masking that fired on the target and nowhere else went unreported:
# the reply named a target the caller never sent, the row held the caller's own spelling, and
# nothing in the object said which of the two it was looking at.

private def with_store(&)
  path = File.tempname("gori-maskedtarget", ".db")
  store = Gori::Store.open(path)
  prev_env = Gori::Settings.project_env_vars
  begin
    yield store
  ensure
    Gori::Settings.project_env_vars = prev_env
    Gori::Env.bump_highlight_rev
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# Through the tool an agent would use: the project's env vars live in the project DB, and
# every call re-reads them (`refresh_project_env`), so a bare `Settings` poke is undone.
private def set_env(store, key : String, value : String) : Nil
  call_json(store, "set_env_var", %({"key":#{key.to_json},"value":#{value.to_json}}))
end

private def call_json(store, name, args : String) : JSON::Any
  tools = Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
  r = tools.call(name, JSON.parse(args))
  fail "#{name} errored: #{r.text}" if r.is_error
  JSON.parse(r.text)
end

describe "MCP repeater target masking" do
  it "names the token when only the TARGET was masked" do
    with_store do |store|
      set_env(store, "SHOP", "https://shop.example")
      # The request carries none of the value, so the old request-only read saw no masking.
      j = call_json(store, "create_repeater",
        %({"target":"https://shop.example","request":"GET /x HTTP/1.1\\r\\nHost: h\\r\\n\\r\\n"}))
      j["target"].as_s.should eq("$SHOP")
      j["secrets_masked"].as_a.map(&.as_s).should eq(["SHOP"])
      j["secrets_masked_note"].as_s.should contain("target")

      # …and the row still holds what the caller sent, which is what the note promises.
      store.get_repeater(j["id"].as_i64).not_nil!.target.should eq("https://shop.example")
    end
  end

  it "names it on update too" do
    with_store do |store|
      created = call_json(store, "create_repeater",
        %({"target":"https://other.example","request":"GET /x HTTP/1.1\\r\\nHost: h\\r\\n\\r\\n"}))
      set_env(store, "SHOP", "https://shop.example")
      j = call_json(store, "update_repeater",
        %({"id":#{created["id"]},"target":"https://shop.example"}))
      j["target"].as_s.should eq("$SHOP")
      j["secrets_masked"].as_a.map(&.as_s).should eq(["SHOP"])
    end
  end

  it "reports each token once when request and target share one" do
    with_store do |store|
      set_env(store, "SHOP", "shop.example")
      j = call_json(store, "create_repeater",
        %({"target":"https://shop.example","request":"GET /x HTTP/1.1\\r\\nHost: shop.example\\r\\n\\r\\n"}))
      j["secrets_masked"].as_a.map(&.as_s).should eq(["SHOP"])
    end
  end

  it "stays silent when nothing was masked" do
    with_store do |store|
      j = call_json(store, "create_repeater",
        %({"target":"https://plain.example","request":"GET /x HTTP/1.1\\r\\nHost: h\\r\\n\\r\\n"}))
      j.as_h.has_key?("secrets_masked").should be_false
    end
  end
end
