require "../spec_helper"

private alias O = Gori::Oast

# `Oast::Sessions` — the surface-free half of "resume a listener". The TUI OAST tab had the
# only implementation of it, so `gori run oast` and the MCP oast_* tools could register and
# die but never come back to a session whose payloads are still planted. These cases pin the
# behaviour all three surfaces now share.
# An Http seam that records what it was asked for and answers a canned body — enough to prove
# release/resume dial (or, for the raising one, that a failure is handled the documented way).
private class RecordingHttp < O::Http
  getter calls = [] of String

  def initialize(@status : Int32 = 200, @body : String = "{}")
  end

  def request(method : String, url : String,
              headers : Hash(String, String) = {} of String => String,
              body : String? = nil) : O::Http::Response
    @calls << "#{method} #{url}"
    O::Http::Response.new(@status, @body)
  end
end

private class ExplodingHttp < O::Http
  def request(method : String, url : String,
              headers : Hash(String, String) = {} of String => String,
              body : String? = nil) : O::Http::Response
    raise Gori::Error.new("network down")
  end
end

private def cfg(id : String, name : String, kind : String, host : String,
                token : String? = nil, scope : String = "project") : O::ProviderConfig
  O::ProviderConfig.new(id, name, kind, host, token, true, scope)
end

private def interaction(uid : String, proto = "http") : O::Interaction
  O::Interaction.new(uid, proto, "GET", "203.0.113.9", "#{uid}.oast.example",
    "GET / HTTP/1.1\r\nHost: #{uid}.oast.example\r\n\r\n", nil, Time.unix(1_700_000_000))
end

describe Gori::Oast::Sessions do
  describe ".list" do
    it "lists sessions newest first, named by their provider, with their callback count" do
      with_store do |store|
        pid = store.insert_oast_provider("lab", "interactsh", "https://oast.lab", "tok", true, 0)
        old = store.insert_oast_session(pid, "interactsh", "https://oast.lab", "corr-old", "sec", nil, nil)
        recent = store.insert_oast_session(pid, "interactsh", "https://oast.lab", "corr-new", "sec", nil, nil)
        store.insert_oast_callback(old, "u1", "dns", nil, "198.51.100.4", "a.oast.lab",
          "q".to_slice, nil, Time.utc.to_unix_ms * 1000)
        store.insert_oast_callback(old, "u2", "http", "GET", "198.51.100.4", "b.oast.lab",
          "GET /".to_slice, nil, Time.utc.to_unix_ms * 1000)
        store.flush

        rows = O::Sessions.list(store, [cfg(pid.to_s, "lab", "interactsh", "https://oast.lab", "tok")])
        # Newest first: a session list is read as a stack (same order as the TUI picker).
        rows.map(&.id).should eq([recent, old])
        rows.last.hits.should eq(2)
        rows.first.hits.should eq(0)
        rows.first.provider.should eq("lab")
        rows.first.provider_key.should eq("p_#{pid}")
        rows.first.payload_host.should eq("oast.lab")
      end
    end

    it "falls back to the kind when the session's provider is gone" do
      with_store do |store|
        store.insert_oast_session(nil, "webhook.site", "https://webhook.site", "corr", "sec", nil, nil)
        store.flush
        row = O::Sessions.list(store, [] of O::ProviderConfig).first
        row.provider.should eq("webhook.site")
        row.provider_key.should be_nil
      end
    end
  end

  describe ".bind" do
    it "rebuilds the engine session from its row, private key included" do
      with_store do |store|
        pem = "-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n-----END PRIVATE KEY-----"
        id = store.insert_oast_session(nil, "interactsh", "https://oast.pro", "corr20", "secret13", pem, nil)
        store.flush
        bound = O::Sessions.bind(store, id, [] of O::ProviderConfig)
        bound = bound.as(O::Sessions::Bound)
        bound.session.id.should eq(id)
        bound.session.correlation_id.should eq("corr20")
        bound.session.secret.should eq("secret13")
        bound.session.private_key_pem.should eq(pem)
        # The row exists because a register once succeeded — resuming must not re-register.
        bound.session.registered?.should be_true
        bound.provider.kind.should eq(O::ProviderKind::Interactsh)
      end
    end

    it "names the row that is not there and the kind it cannot build" do
      with_store do |store|
        O::Sessions.bind(store, 999_i64, [] of O::ProviderConfig)
          .should eq(O::Sessions::Problem::Missing)
        id = store.insert_oast_session(nil, "not-a-kind", "https://x.example", "c", "s", nil, nil)
        store.flush
        O::Sessions.bind(store, id, [] of O::ProviderConfig)
          .should eq(O::Sessions::Problem::UnknownKind)
        O::Sessions.message_for(O::Sessions::Problem::Missing, 4_i64).should contain("no OAST session #4")
      end
    end

    it "dials the SESSION's server even when the provider row was re-pointed, but prefers the provider's TOKEN" do
      with_store do |store|
        pid = store.insert_oast_provider("lab", "BOAST", "https://moved.example", "rotated", true, 0)
        id = store.insert_oast_session(pid, "BOAST", "https://original.example", "corr", "sec", nil, "stale")
        store.flush
        bound = O::Sessions.bind(store, id,
          [cfg(pid.to_s, "lab", "BOAST", "https://moved.example", "rotated")]).as(O::Sessions::Bound)
        # The secrets only mean anything to the server that minted them.
        bound.session.server_url.should eq("https://original.example")
        bound.provider.host.should eq("https://original.example")
        # A rotated credential is the live one.
        bound.provider.token.should eq("rotated")
        bound.label.should eq("lab")
      end
    end

    it "re-resolves a GLOBAL provider's session by kind + normalised endpoint" do
      with_store do |store|
        # A global provider has no row in this project's DB, so the register stored a NULL
        # provider_id — every one of those sessions would be unresumable without this.
        id = store.insert_oast_session(nil, "interactsh", "https://oast.pro", "corr", "sec", nil, nil)
        store.flush
        bound = O::Sessions.bind(store, id,
          [cfg("deadbeef", "shared", "interactsh", "oast.pro", "gtok", scope: "global")]).as(O::Sessions::Bound)
        bound.label.should eq("shared")
        bound.config.try(&.global?).should be_true
        bound.provider.token.should eq("gtok")
      end
    end

    it "binds a session whose provider is gone (a headless resume has no listener registry)" do
      with_store do |store|
        id = store.insert_oast_session(nil, "custom-http", "https://oob.example/hits", "corr", "", nil, "own")
        store.flush
        bound = O::Sessions.bind(store, id, [] of O::ProviderConfig).as(O::Sessions::Bound)
        bound.config.should be_nil
        bound.label.should eq("custom-http")
        bound.provider.token.should eq("own") # the row's own token is all a poll needs
      end
    end

    # `oast_providers.id` is a plain INTEGER PRIMARY KEY with no AUTOINCREMENT, so SQLite hands
    # a deleted row's id to the next insert. A session pointing at the old row then re-binds to
    # whatever took that id — and since `bind` takes the HOST from the session and the TOKEN
    # from the config, that is a webhook.site api key sent as `Authorization:` to an interactsh
    # host. The id is only an identity when the KIND agrees.
    it "refuses a provider row whose id was reused by a different kind" do
      with_store do |store|
        first = store.insert_oast_provider("Corp", "interactsh", "https://oast.corp", "CORP", true, 0)
        second = store.insert_oast_provider("Second", "interactsh", "https://oast.other.internal",
          "OTHER", true, 1)
        id = store.insert_oast_session(second, "interactsh", "https://oast.other.internal",
          "corr", "sec", nil, "OTHER")
        store.delete_oast_provider(second)
        store.flush
        # The row id is free again; the next insert takes it.
        reused = store.insert_oast_provider("Public webhook.site", "webhook.site",
          "https://webhook.site", "MY-WEBHOOK-API-KEY", true, 2)
        store.flush
        reused.should eq(second) # the premise — if SQLite stopped reusing ids, so does the bug
        first.should_not eq(second)

        # Built from the DB rows only — `Oast.provider_configs` would merge the machine's own
        # GLOBAL provider library into a spec that is about this project's rows.
        configs = store.oast_providers.map { |p| cfg(p.id.to_s, p.name, p.kind, p.host, p.token) }
        rec = store.get_oast_session(id).not_nil!
        # The delete already NULLed the pointer, so nothing dangles in the first place…
        rec.provider_id.should be_nil
        # …and even handed the stale pointer directly, the kind check refuses it.
        stale = Gori::Store::OastSessionRecord.new(rec.id, rec.created_at, second, rec.kind,
          rec.server_url, rec.correlation_id, rec.secret, rec.private_key_pem, rec.token,
          rec.last_poll_at)
        cfg = O::Sessions.config_for(stale, configs)
        cfg.try(&.name).should_not eq("Public webhook.site")
        cfg.try(&.token).should_not eq("MY-WEBHOOK-API-KEY")

        bound = O::Sessions.bind(store, id).as(O::Sessions::Bound)
        bound.provider.kind.should eq(O::ProviderKind::Interactsh)
        bound.provider.host.should eq("https://oast.other.internal")
        bound.provider.token.should_not eq("MY-WEBHOOK-API-KEY")
      end
    end

    # The other half of the same column: deleting a provider used to strand every session it
    # minted with a nil provider_key, which the TUI reads as "not resumable" — permanently, even
    # after the operator re-added the identical provider.
    it "finds a provider deleted and re-added, by kind + endpoint" do
      with_store do |store|
        pid = store.insert_oast_provider("Corp", "interactsh", "oast.corp", "CORP", true, 0)
        id = store.insert_oast_session(pid, "interactsh", "https://oast.corp", "corr", "sec", nil, nil)
        store.delete_oast_provider(pid)
        store.flush
        store.get_oast_session(id).not_nil!.provider_id.should be_nil
        again = store.insert_oast_provider("Corp", "interactsh", "oast.corp", "CORP2", true, 0)
        store.flush
        info = O::Sessions.list(store).find! { |r| r.id == id }
        info.provider.should eq("Corp")
        info.provider_key.should eq("p_#{again}")
        O::Sessions.bind(store, id).as(O::Sessions::Bound).provider.token.should eq("CORP2")
      end
    end

    it "accepts the id when the kind agrees, even after the provider's host was edited" do
      with_store do |store|
        pid = store.insert_oast_provider("lab", "interactsh", "https://moved.example", "rotated", true, 0)
        rec = Gori::Store::OastSessionRecord.new(1_i64, 0_i64, pid, "interactsh",
          "https://original.example", "corr", "sec", nil, nil, nil)
        O::Sessions.config_for(rec, [cfg(pid.to_s, "lab", "interactsh", "https://moved.example",
          "rotated")]).try(&.name).should eq("lab")
      end
    end
  end

  describe ".resume / .release" do
    it "re-arms interactsh against the persisted correlation id" do
      with_store do |store|
        rsa = O::RsaKeyPair.generate_2048
        id = store.insert_oast_session(nil, "interactsh", "https://oast.pro", "corr20", "secret13",
          rsa.private_pem, nil)
        store.flush
        bound = O::Sessions.bind(store, id, [] of O::ProviderConfig).as(O::Sessions::Bound)
        http = RecordingHttp.new(200, "{}")
        O::Sessions.resume(bound, http)
        http.calls.should eq(["POST https://oast.pro/register"])
      end
    end

    it "raises when the resume did not take (the operator asked for the session back)" do
      with_store do |store|
        rsa = O::RsaKeyPair.generate_2048
        id = store.insert_oast_session(nil, "interactsh", "https://oast.pro", "corr20", "secret13",
          rsa.private_pem, nil)
        store.flush
        bound = O::Sessions.bind(store, id, [] of O::ProviderConfig).as(O::Sessions::Bound)
        expect_raises(Gori::Error) { O::Sessions.resume(bound, RecordingHttp.new(500, "nope")) }
      end
    end

    it "releases best-effort and keeps the row and its callbacks" do
      with_store do |store|
        id = store.insert_oast_session(nil, "interactsh", "https://oast.pro", "corr", "sec", nil, nil)
        store.insert_oast_callback(id, "u1", "dns", nil, "198.51.100.4", "a.oast.pro",
          "q".to_slice, nil, Time.utc.to_unix_ms * 1000)
        store.flush
        bound = O::Sessions.bind(store, id, [] of O::ProviderConfig).as(O::Sessions::Bound)
        # Answers rather than raising: a release can run during teardown, where an exception
        # is noise, but the CLI still needs to know it failed.
        outcome = O::Sessions.release_outcome(bound, ExplodingHttp.new)
        outcome.should eq(O::Sessions::Release::Failed)
        outcome.torn_down?.should be_false
        # This releases the LISTENER, not the evidence.
        store.oast_sessions.map(&.id).should contain(id)
        store.oast_callback_count(id).should eq(1)
      end
    end

    # The defect this describe block exists for: `Provider#deregister` is a no-op by default, so
    # four of the five backends answered `release` with `true` and NO packet. Three surfaces then
    # printed "released … payloads minted from it stop resolving" over a webhook.site token still
    # collecting the target's traffic on a public service.
    it "actually deletes a webhook.site token, and says so" do
      with_store do |store|
        id = store.insert_oast_session(nil, "webhook.site", "https://webhook.site",
          "11111111-2222-3333-4444-555555555555", "", nil, "MY-WEBHOOK-API-KEY")
        store.flush
        bound = O::Sessions.bind(store, id, [] of O::ProviderConfig).as(O::Sessions::Bound)
        http = RecordingHttp.new(200, "{}")
        O::Sessions.release_outcome(bound, http).should eq(O::Sessions::Release::Released)
        http.calls.should eq(
          ["DELETE https://webhook.site/token/11111111-2222-3333-4444-555555555555"])
        O::Sessions.release_message(O::Sessions::Release::Released, bound, id, 2)
          .should eq("released OAST session ##{id} — its 2 callbacks stay.")
      end
    end

    it "actually deletes a postbin bin" do
      with_store do |store|
        id = store.insert_oast_session(nil, "postbin", "https://www.toptal.com/developers/postbin",
          "1234-5678-9012", "", nil, "1234-5678-9012")
        store.flush
        bound = O::Sessions.bind(store, id, [] of O::ProviderConfig).as(O::Sessions::Bound)
        http = RecordingHttp.new(200, "{}")
        O::Sessions.release_outcome(bound, http).should eq(O::Sessions::Release::Released)
        http.calls.should eq(
          ["DELETE https://www.toptal.com/developers/postbin/api/bin/1234-5678-9012"])
      end
    end

    # A rotated api key answers 401 and the token stays live — that must not read as a teardown.
    it "reports a refused delete as a failure, not a release" do
      with_store do |store|
        id = store.insert_oast_session(nil, "webhook.site", "https://webhook.site", "uuid", "",
          nil, "rotated-away")
        store.flush
        bound = O::Sessions.bind(store, id, [] of O::ProviderConfig).as(O::Sessions::Bound)
        O::Sessions.release_outcome(bound, RecordingHttp.new(401, "unauthorized"))
          .should eq(O::Sessions::Release::Failed)
        # …but an already-gone token is the state the caller asked for.
        O::Sessions.release_outcome(bound, RecordingHttp.new(404, "not found"))
          .should eq(O::Sessions::Release::Released)
      end
    end

    # BOAST registers server-side state and offers no way to release it. The honest answer is
    # "not released", and it must reach the operator as a sentence naming the provider — a
    # silent success is what let an engagement end with a live third-party listener.
    it "refuses to claim a release for a backend that has no deregistration API" do
      with_store do |store|
        id = store.insert_oast_session(nil, "BOAST", "https://odiss.eu", "corr", "sec", nil, "tok")
        store.flush
        bound = O::Sessions.bind(store, id, [] of O::ProviderConfig).as(O::Sessions::Bound)
        http = RecordingHttp.new(200, "{}")
        outcome = O::Sessions.release_outcome(bound, http)
        outcome.should eq(O::Sessions::Release::Unsupported)
        outcome.torn_down?.should be_false
        http.calls.should be_empty # not a failed request — no request at all
        msg = O::Sessions.release_message(outcome, bound, id, 1)
        msg.should contain("was NOT released")
        msg.should contain("BOAST")
        msg.should contain("keep resolving")
        msg.should contain("its 1 callback stays")
      end
    end

    # custom-http is the third state: `register` mints a correlation id locally and dials
    # nothing, so there is no third-party registration to release. Reporting that as a refusal
    # would be as wrong as reporting the others as a success.
    it "reports a custom-http session as needing no release" do
      with_store do |store|
        id = store.insert_oast_session(nil, "custom-http", "https://oob.example/hits", "corr", "",
          nil, nil)
        store.flush
        bound = O::Sessions.bind(store, id, [] of O::ProviderConfig).as(O::Sessions::Bound)
        http = RecordingHttp.new(200, "{}")
        outcome = O::Sessions.release_outcome(bound, http)
        outcome.should eq(O::Sessions::Release::NoServerState)
        outcome.torn_down?.should be_true
        http.calls.should be_empty
        O::Sessions.release_message(outcome, bound, id, 0).should contain("needed no release")
      end
    end
  end

  describe ".record_callback / .seen_uids" do
    it "persists an interaction under its own timestamp and dedups a re-poll" do
      with_store do |store|
        id = store.insert_oast_session(nil, "interactsh", "https://oast.pro", "corr", "sec", nil, nil)
        store.flush
        i = interaction("uid-1")
        O::Sessions.record_callback(store, id, i)
        O::Sessions.record_callback(store, id, i) # a provider that replays its buffer
        store.flush
        store.oast_callback_count(id).should eq(1)
        row = store.oast_callbacks(id).first
        row.created_at.should eq(i.at.to_unix_ms * 1000)
        row.protocol.should eq("http")
        O::Sessions.seen_uids(store, id).should eq(Set{"uid-1"})
      end
    end

    it "keeps a DNS callback that carries no raw request" do
      with_store do |store|
        id = store.insert_oast_session(nil, "interactsh", "https://oast.pro", "corr", "sec", nil, nil)
        store.flush
        O::Sessions.record_callback(store, id,
          O::Interaction.new("dns-1", "dns", nil, "198.51.100.4", "a.oast.pro", "", nil, Time.utc))
        store.flush
        store.oast_callback_count(id).should eq(1)
      end
    end
  end

  describe ".parse_id" do
    it "accepts what the tables print and refuses what is not a row id" do
      O::Sessions.parse_id("7").should eq(7_i64)
      O::Sessions.parse_id("#7").should eq(7_i64)
      O::Sessions.parse_id(" 12 ").should eq(12_i64)
      O::Sessions.parse_id("0").should be_nil
      O::Sessions.parse_id("-3").should be_nil
      O::Sessions.parse_id("p_1").should be_nil
      O::Sessions.parse_id("").should be_nil
    end
  end
end
