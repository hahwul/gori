require "./spec_helper"

private def with_store(&)
  path = File.tempname("gori-saved-views", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# The global view library is process-wide state (Settings), so every example that writes it
# restores what it found — `SavedViews.merged` folds it into EVERY project's list. And it is a
# FILE as much as it is memory: every global CRUD re-reads its own section before it mutates
# (`reload_saved_views_from_disk`, so two gori processes cannot mint the same view id), which
# makes the suite-wide settings.json shared state between examples. Same harness, and the same
# reasoning, as spec/colormarker_spec.cr's `with_globals`.
private def with_globals(&)
  before = Gori::Settings.saved_views
  counter = Gori::Settings.saved_views_next_id
  prev_home = ENV["GORI_HOME"]?
  dir = File.tempname("gori-saved-views-globals")
  Dir.mkdir_p(dir)
  begin
    ENV["GORI_HOME"] = dir
    Gori::Settings.saved_views = [] of Gori::Settings::SavedView
    Gori::Settings.saved_views_next_id = 1_i64
    yield
  ensure
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    Gori::Settings.saved_views = before
    Gori::Settings.saved_views_next_id = counter
    FileUtils.rm_rf(dir)
  end
end

# `Settings.save` refusing every write, reached without lock contention and without touching
# Settings' in-memory state — the `File.chmod` lever spec/colormarker_spec.cr uses.
private def with_unwritable_settings(&)
  jail = File.tempname("gori-saved-views-settings")
  Dir.mkdir_p(jail)
  dir = File.join(jail, "home") # never created: the parent below refuses it
  prev_home = ENV["GORI_HOME"]?
  begin
    ENV["GORI_HOME"] = dir
    File.chmod(jail, 0o500)
    Gori::Settings.save.should be_false # the lever works
    yield
  ensure
    File.chmod(jail, 0o700)
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    FileUtils.rm_rf(jail)
  end
end

private def flow(store, host : String, source : Gori::FlowSource::Kind) : Int64
  store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: host, port: 443,
    method: "GET", target: "/", http_version: "HTTP/1.1",
    head: "GET / HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice, source: source))
end

describe Gori::SavedViews do
  describe "built-ins" do
    it "ships a source trio, a protocol trio and Errors in every project" do
      with_globals do
        with_store do |store|
          Gori::SavedViews.merged(store).map(&.name).should eq(
            ["All", "History", "History + Repeater", "WebSocket", "gRPC", "SSE", "Errors"])
        end
      end
    end

    it "keeps the source and protocol axes apart rather than pre-combining them" do
      # A `WebSocket` view that also excluded an imported socket would be lying about its own
      # name. The axes compose through the LENS instead: a view ANDs over the filter bar, so
      # `History + Repeater` plus a typed `proto:ws` is the intersection, and no built-in has to
      # anticipate another.
      by_name = Gori::SavedViews::BUILTINS.to_h { |v| {v.name, v.query} }
      by_name["WebSocket"].should eq("proto:ws")
      by_name["gRPC"].should eq("proto:grpc")
      by_name["SSE"].should eq("proto:sse")
      by_name["Errors"].should eq("status:>=400")
      # BARE spellings: `proto:ws` matches the cleartext and TLS rows alike, and the transport
      # is a separate question from "is this a socket".
      Gori::SavedViews::BUILTINS.none? { |v| v.query.includes?("wss") || v.query.includes?("grpcs") }.should be_true
    end

    it "compiles every built-in — a shipped view that narrows nothing is the failure this guards" do
      Gori::SavedViews::BUILTINS.each do |v|
        next unless v.narrowing?
        Gori::SavedViews.unusable_query_reason(v.query).should be_nil
        Gori::SavedViews.filter(v).should_not be_nil
      end
    end

    it "gives All an empty query, so 'no view' and 'the All view' are the same filter" do
      Gori::SavedViews.all_view.query.should eq("")
      Gori::SavedViews.all_view.narrowing?.should be_false
      Gori::SavedViews.filter(Gori::SavedViews.all_view).should eq(Gori::QL::EMPTY)
      Gori::SavedViews.filter(nil).should eq(Gori::QL::EMPTY)
    end

    it "narrows History to src:proxy and not to -src:gori — an import is neither" do
      with_globals do
        with_store do |store|
          flow(store, "proxied.test", Gori::FlowSource::Kind::Proxy)
          flow(store, "resent.test", Gori::FlowSource::Kind::Repeater)
          flow(store, "imported.test", Gori::FlowSource::Kind::Import)

          history = Gori::SavedViews.merged(store).find { |v| v.name == "History" }.not_nil!
          rows = store.search(Gori::SavedViews.filter(history).not_nil!, 50)
          rows.map(&.host).should eq(["proxied.test"])

          both = Gori::SavedViews.merged(store).find { |v| v.name == "History + Repeater" }.not_nil!
          store.search(Gori::SavedViews.filter(both).not_nil!, 50).map(&.host)
            .should eq(["resent.test", "proxied.test"])
        end
      end
    end

    it "keys each scope apart, so a project and a global id of 3 cannot collide" do
      Gori::SavedViews::View.new("3", "a", "x:1", "project").key.should eq("p_3")
      Gori::SavedViews::View.new("3", "a", "x:1", "global").key.should eq("g_3")
      Gori::SavedViews.all_view.key.should eq("b_all")
      # A builtin id may contain '_', so a reader splits at the FIRST underscore only.
      Gori::SavedViews::View.new("proxy+repeater", "n", "q", "builtin").key.split('_', 2)
        .should eq(["b", "proxy+repeater"])
    end
  end

  describe "validation" do
    it "refuses a query that would narrow nothing, rather than applying it as match-all" do
      # The whole reason this is a REFUSAL: `QL.and` folds an EMPTY side away, so a view whose
      # every term drops shows every flow while a `v:` chip claims a filter is on.
      Gori::SavedViews.unusable_query_reason("").should eq("enter a query")
      Gori::SavedViews.unusable_query_reason("src:nope")
        .should eq("this query matches every flow — it would narrow nothing")
      Gori::SavedViews.unusable_query_reason("bogus:x").not_nil!.should contain("unknown field")
      Gori::SavedViews.unusable_query_reason("host~[").not_nil!.should contain("not a valid regex")
      Gori::SavedViews.unusable_query_reason("src:proxy").should be_nil
      # `res.body:` is a spelling QL compiles but does not OFFER, so testing against the offered
      # pool would refuse a perfectly good view.
      Gori::SavedViews.unusable_query_reason("res.body:token").should be_nil
    end

    it "refuses a name that would shadow a built-in, since --view could never reach it again" do
      Gori::SavedViews.unusable_name_reason("").should eq("enter a name")
      Gori::SavedViews.unusable_name_reason("all").not_nil!.should contain("built-in")
      Gori::SavedViews.unusable_name_reason("History + Repeater").not_nil!.should contain("built-in")
      Gori::SavedViews.unusable_name_reason("x" * (Gori::SavedViews::NAME_MAX + 1))
        .not_nil!.should contain("longer than")
      Gori::SavedViews.unusable_name_reason("acme errors").should be_nil
    end

    it "refuses a control character in either half, because both halves get PRINTED" do
      # The TUI grid substitutes a control cell with a space; a terminal written to directly does
      # not. A newline in a name breaks `gori run views list`'s one-line-per-view contract and an
      # ESC emits its own sequence — and the TUI's prompt cannot type either, so the CLI and MCP
      # are the two surfaces that have to be stopped here.
      Gori::SavedViews.unusable_name_reason("two\nlines").should eq("name contains a control character")
      Gori::SavedViews.unusable_name_reason("red\e[31m").should eq("name contains a control character")
      Gori::SavedViews.unusable_name_reason("tab\there").should eq("name contains a control character")
      Gori::SavedViews.unusable_query_reason("src:proxy\e[31m").should eq("query contains a control character")
      # Named BEFORE the parse: `\n` is whitespace to the QL tokenizer, so a query holding one
      # compiles cleanly and would sail past every check below it.
      Gori::SavedViews.unusable_query_reason("src:proxy\nOR src:repeater")
        .should eq("query contains a control character")
      # A plain space is not a control character, and a name is allowed to be a phrase.
      Gori::SavedViews.unusable_name_reason("acme errors").should be_nil
    end

    it "refuses a broken view at APPLY time too, because a peer can write one behind us" do
      broken = Gori::SavedViews::View.new("1", "broken", "src:nope", "project")
      Gori::SavedViews.filter(broken).should be_nil
    end
  end

  describe "the two scopes" do
    it "merges builtins, then the global library, then this project's own" do
      with_globals do
        with_store do |store|
          Gori::Settings.add_saved_view("everywhere", "src:proxy").should_not eq(0)
          store.insert_saved_view("here", "host:acme.test").should_not eq(0)
          Gori::SavedViews.merged(store).map { |v| {v.scope, v.name} }
            .should eq(Gori::SavedViews::BUILTINS.map { |v| {"builtin", v.name} } +
                       [{"global", "everywhere"}, {"project", "here"}])
        end
      end
    end

    it "resolves a colliding name project > global > builtin" do
      with_globals do
        with_store do |store|
          Gori::Settings.add_saved_view("dupe", "src:repeater")
          store.insert_saved_view("dupe", "host:acme.test")
          found = Gori::SavedViews.resolve_by_name(store, "DUPE").not_nil!
          found.scope.should eq("project")
          found.query.should eq("host:acme.test")

          Gori::SavedViews.remove(store, found).should be_true
          Gori::SavedViews.resolve_by_name(store, "dupe").not_nil!.scope.should eq("global")
        end
      end
    end

    it "keeps names unique WITHIN a scope, at the index as well as the check" do
      with_globals do
        with_store do |store|
          store.insert_saved_view("here", "host:a").should_not eq(0)
          Gori::SavedViews.name_taken?(store, "HERE", "project").should be_true
          Gori::SavedViews.name_taken?(store, "here", "global").should be_false
          # The UNIQUE index is the backstop for a race between the check and the insert.
          store.insert_saved_view("HERE", "host:b").should eq(0)
        end
      end
    end

    it "DROPS a duplicate write instead of raising it into the writer batch" do
      # The reason this matters is not the view. A raise inside `exec_task` is caught by the
      # writer loop's per-batch rescue, which rolls back the WHOLE batch — captured flows
      # included — and marks the connection suspect. A duplicate name must cost the view, not
      # the capture running beside it. Proven by writing a flow in the same window and finding
      # it still there.
      with_globals do
        with_store do |store|
          store.insert_saved_view("dupe", "host:a").should_not eq(0)
          store.insert_saved_view("dupe", "host:b").should eq(0)
          flow(store, "survivor.test", Gori::FlowSource::Kind::Proxy).should_not eq(0)
          store.recent_flows(10).map(&.host).should contain("survivor.test")
          store.saved_views.map(&.query).should eq(["host:a"]) # the first write, unmodified
        end
      end
    end

    it "reports a rename onto a taken name, and an unknown id, as NOT updated" do
      with_globals do
        with_store do |store|
          a = store.insert_saved_view("a", "host:a")
          store.insert_saved_view("b", "host:b")
          store.update_saved_view(a, "b", "host:a").should be_false        # collides
          store.update_saved_view(9999_i64, "z", "host:z").should be_false # gone
          store.saved_views.map(&.name).sort!.should eq(["a", "b"])
        end
      end
    end

    it "moves a view between scopes destination-first, and undoes the copy if the source stays" do
      with_globals do
        with_store do |store|
          store.insert_saved_view("promote me", "src:proxy")
          view = Gori::SavedViews.merged(store).find(&.project?).not_nil!
          moved = Gori::SavedViews.set_scope(store, view, "global").not_nil!
          moved.scope.should eq("global")
          moved.query.should eq("src:proxy")
          Gori::SavedViews.merged(store).select { |v| !v.builtin? }.map(&.scope).should eq(["global"])
        end
      end
    end

    it "carries the new name INTO the move, not as an edit afterwards" do
      # A move-and-rename that inserted under the OLD name would be checked for availability
      # under one name and written under another: the project store answers that with a dropped
      # UNIQUE write, and settings.json — which enforces nothing — with two global views sharing
      # a name that `resolve_by_name` then picks between forever.
      with_globals do
        with_store do |store|
          store.insert_saved_view("old name", "src:proxy")
          view = Gori::SavedViews.merged(store).find(&.project?).not_nil!
          moved = Gori::SavedViews.set_scope(store, view, "global", "new name", "src:repeater").not_nil!
          moved.name.should eq("new name")
          moved.query.should eq("src:repeater")
          Gori::Settings.saved_views.map(&.name).should eq(["new name"])
          # And no intermediate row under the old name survived in either store.
          Gori::SavedViews.merged(store).select { |v| !v.builtin? }.map(&.name).should eq(["new name"])
        end
      end
    end

    it "refuses to move a built-in" do
      with_globals do
        with_store do |store|
          Gori::SavedViews.set_scope(store, Gori::SavedViews.all_view, "project").should be_nil
          Gori::SavedViews.remove(store, Gori::SavedViews.all_view).should be_false
          Gori::SavedViews.update(store, Gori::SavedViews.all_view, "x", "src:proxy").should be_false
        end
      end
    end
  end

  describe "the active view" do
    it "defaults to History + Repeater, round-trips a pick, and reports a deleted one as GONE" do
      with_globals do
        with_store do |store|
          # The flows gori's own crawler/fuzzer/importer wrote are not evidence about the
          # target, so the list does not open mixing them in.
          Gori::SavedViews.active(store).not_nil!.name.should eq("History + Repeater")

          store.insert_saved_view("mine", "src:proxy")
          view = Gori::SavedViews.merged(store).find(&.project?).not_nil!
          Gori::SavedViews.set_active(store, view).should be_true
          Gori::SavedViews.active(store).not_nil!.key.should eq(view.key)

          # nil, NOT all_view: a caller has to be able to tell "no view" from "the view you had
          # is gone", because only the second one is worth a sentence on screen.
          Gori::SavedViews.remove(store, view).should be_true
          Gori::SavedViews.active(store).should be_nil
        end
      end
    end

    it "defaults to All on a project captured before provenance was recorded" do
      # `src:` matches those rows in NEITHER direction, so the ordinary default would open an
      # old engagement on an empty list however much traffic it holds.
      with_globals do
        with_store do |store|
          id = flow(store, "old.test", Gori::FlowSource::Kind::Proxy)
          store.@db.exec("UPDATE flows SET source = NULL WHERE id = ?", id)
          store.pre_provenance_flows?.should be_true
          Gori::SavedViews.default_view(store).name.should eq("All")
          Gori::SavedViews.active(store).not_nil!.name.should eq("All")
        end
      end
    end

    it "keeps the default once the pre-provenance rows are gone" do
      with_globals do
        with_store do |store|
          flow(store, "new.test", Gori::FlowSource::Kind::Proxy)
          store.pre_provenance_flows?.should be_false
          Gori::SavedViews.default_view(store).name.should eq("History + Repeater")
        end
      end
    end

    it "writes All EXPLICITLY, so a cleared choice is not re-read as 'nobody has chosen'" do
      with_globals do
        with_store do |store|
          Gori::SavedViews.set_active(store, nil).should be_true
          store.setting(Gori::SavedViews::ACTIVE_KEY).should eq("b_all")
          Gori::SavedViews.active(store).not_nil!.name.should eq("All")
        end
      end
    end

    it "clears back to All" do
      with_globals do
        with_store do |store|
          store.insert_saved_view("mine", "src:proxy")
          Gori::SavedViews.set_active(store, Gori::SavedViews.merged(store).find(&.project?))
          Gori::SavedViews.set_active(store, nil).should be_true
          Gori::SavedViews.active(store).not_nil!.name.should eq("All")
        end
      end
    end
  end

  describe "write-commit reporting" do
    it "answers nil from add when the GLOBAL write did not reach disk, and keeps memory clean" do
      with_globals do
        with_store do |store|
          with_unwritable_settings do
            Gori::SavedViews.add(store, "nope", "src:proxy", "global").should be_nil
            # Neither the view nor the burned id may survive a refused save: a project's
            # `history_view` key outlives the view it names, which is why ids are never reused.
            Gori::Settings.saved_views.should be_empty
            Gori::Settings.saved_views_next_id.should eq(1_i64)
          end
        end
      end
    end

    it "answers false from update/delete when the GLOBAL write did not reach disk" do
      with_globals do
        with_store do |store|
          id = Gori::Settings.add_saved_view("live", "src:proxy")
          id.should_not eq(0)
          view = Gori::SavedViews.merged(store).find(&.global?).not_nil!
          with_unwritable_settings do
            Gori::SavedViews.update(store, view, "renamed", "src:repeater").should be_false
            Gori::SavedViews.remove(store, view).should be_false
            Gori::Settings.saved_views.map(&.name).should eq(["live"])
          end
        end
      end
    end
  end

  describe "settings round-trip" do
    it "writes numeric ids, so the concurrent merge can identify an entry" do
      with_globals do
        Gori::Settings.add_saved_view("acme", "host:acme.test").should eq(1_i64)
        doc = JSON.parse(File.read(Gori::Settings.path)).as_h["saved_views"].as_h
        doc["next_view_id"].as_i64.should eq(2_i64)
        entry = doc["views"].as_a.first.as_h
        # A STRING id here would make `Settings.entry_identity` answer nil, which drops the
        # whole section to a blob merge — and a peer's concurrently created view with it.
        entry["id"].as_i64.should eq(1_i64)
        entry["name"].as_s.should eq("acme")
        entry["query"].as_s.should eq("host:acme.test")
      end
    end

    it "drops a hand-edited entry with no query rather than adding a second silent All" do
      with_globals do
        File.write(Gori::Settings.path, <<-JSON)
          {"saved_views":{"next_view_id":9,"views":[
            {"id":1,"name":"good","query":"src:proxy"},
            {"id":2,"name":"noquery","query":""},
            {"id":3,"name":"","query":"src:proxy"},
            {"id":4,"name":"GOOD","query":"host:dupe"}
          ]}}
          JSON
        Gori::Settings.load
        # First name wins on a duplicate, so the file loads deterministically and
        # `resolve_by_name` cannot depend on array order.
        Gori::Settings.saved_views.map(&.name).should eq(["good"])
        Gori::Settings.saved_views_next_id.should eq(9_i64)
      end
    end

    it "keeps the counter across a factory reset, so a stale history_view cannot be re-pointed" do
      with_globals do
        Gori::Settings.add_saved_view("a", "src:proxy")
        Gori::Settings.add_saved_view("b", "src:repeater")
        Gori::Settings.reset_to_factory
        Gori::Settings.saved_views.should be_empty
        Gori::Settings.saved_views_next_id.should eq(3_i64)
      end
    end
  end
end
