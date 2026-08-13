require "./spec_helper"
require "compress/gzip"

private def with_store(&)
  path = File.tempname("gori-colormarker", ".db")
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

# The global rule library is process-wide state (Settings), so every example that writes it
# restores what it found — `Colormarker.load` merges it into EVERY project's rule list.
private def with_globals(&)
  before = Gori::Settings.colormarker_rules
  counter = Gori::Settings.colormarker_next_rule_id
  begin
    Gori::Settings.colormarker_rules = [] of Gori::Settings::ColormarkerRule
    Gori::Settings.colormarker_next_rule_id = 1_i64
    yield
  ensure
    Gori::Settings.colormarker_rules = before
    Gori::Settings.colormarker_next_rule_id = counter
  end
end

# A REAL flow in the store, handed back as the `FlowRow` `match` is asked about. Store-tier
# rules resolve by flow id, so the synthetic `row` below — whose id names no flow — would answer
# "no" for the wrong reason and pin nothing.
private def captured(store, host : String, target : String, *,
                     body : String? = nil, body_bytes : Bytes? = nil,
                     head : String? = nil, status : Int32? = 200) : Gori::Store::FlowRow
  req_head = head || "POST #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n"
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: host, port: 443,
    method: "POST", target: target, http_version: "HTTP/1.1",
    head: req_head.to_slice, body: body_bytes || body.try(&.to_slice)))
  if status
    store.update_response(Gori::Store::CapturedResponse.new(
      flow_id: id, status: status, head: "HTTP/1.1 #{status} OK\r\n\r\n".to_slice))
  end
  store.flow_row(id).not_nil!
end

private def row(id : Int64 = 1_i64, method : String = "GET", host : String = "acme.test",
                target : String = "/", scheme : String = "https", status : Int32? = 200,
                content_type : String? = "text/html")
  Gori::Store::FlowRow.new(id, 0_i64, scheme, method, host, 443, target, status, 0_i64,
    Gori::Store::FlowState::Complete, content_type: content_type)
end

# A rule's colour is a LABEL string now (a built-in word or a custom colour's name), so these
# are the strings the engine stores and `mark_color` resolves — not the `MarkerColor` enum.
private RED    = "red"
private BLUE   = "blue"
private YELLOW = "yellow"
private FULL   = Gori::Store::MarkerStyle::Full
private STRIP  = Gori::Store::MarkerStyle::Strip
private GLOBAL = Gori::Store::RuleScope::Global

describe Gori::Colormarker do
  describe "#match" do
    # The single claim that separates a colour rule from a rewrite rule: rewrite rules
    # COMPOSE, colour rules RESOLVE. The loser must contribute NOTHING — not its colour and
    # not its style, which is why the assertion checks both.
    it "resolves the FIRST matching rule and never consults the rest" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("status:5xx", RED, FULL, "first")
          cm.add("host:acme", BLUE, STRIP, "second")

          hit = cm.match(row(status: 500))
          hit.should_not be_nil
          hit.not_nil!.name.should eq("first")
          hit.not_nil!.color.should eq(RED)
          hit.not_nil!.style.should eq(FULL)

          # a row only the second rule matches still resolves
          cm.match(row(status: 200)).not_nil!.name.should eq("second")
        end
      end
    end

    it "applies global rules before project rules" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:acme", BLUE, STRIP, "project rule")
          cm.add("host:acme", RED, FULL, "standing policy", scope: GLOBAL)

          cm.rules.map(&.scope).should eq([GLOBAL, Gori::Store::RuleScope::Project])
          # Both match; the global one wins, because a standing policy outranks a local layer.
          cm.match(row).not_nil!.name.should eq("standing policy")
        end
      end
    end

    it "skips a disabled rule and falls through to the next" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:acme", RED, FULL, "off")
          cm.add("host:acme", BLUE, FULL, "on")
          cm.toggle(cm.rules.first.id).should be_true
          cm.match(row).not_nil!.name.should eq("on")
        end
      end
    end

    it "matches nothing when no rule is enabled" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.active?.should be_false
          cm.match(row).should be_nil
          cm.add("host:acme", RED, FULL)
          cm.active?.should be_true
        end
      end
    end

    # The STORE tier. A `body:` rule used to parse fine and paint nothing — `Subject.payload` is
    # nil for a captured row — so the engine answered "no" for every row and said so only in a
    # note. It now compiles to QL and asks the store, which is the whole point of the tier split.
    it "paints a row whose stored body matches a `body:` term" do
      with_globals do
        with_store do |store|
          hit = captured(store, "acme.test", "/login", body: "username=admin&csrf=SeCrEtToken")
          miss = captured(store, "acme.test", "/about", body: "nothing here")
          cm = Gori::Colormarker.load(store)
          cm.add("body:secrettoken", RED, FULL, "leak") # case-insensitive, like History's body:
          cm.needs_store?.should be_true
          cm.match(hit).not_nil!.name.should eq("leak")
          cm.match(miss).should be_nil
        end
      end
    end

    # The reason Colormarker compiles with `fts: false`. Indexing is off-commit, so a row
    # captured a moment ago has no `flows_fts` row yet — and the render path can neither drain
    # the backlog nor wait for it. Nothing here calls `index_pending!`, which is the assertion:
    # the rule must paint the flow that just arrived, not the flow the indexer has caught up to.
    it "matches a body the text index has not indexed yet" do
      with_globals do
        with_store do |store|
          fresh = captured(store, "acme.test", "/upload", body: "id=1&token=freshvalue")
          cm = Gori::Colormarker.load(store)
          cm.add("body:freshvalue", RED, FULL, "fresh")
          cm.match(fresh).not_nil!.name.should eq("fresh")
        end
      end
    end

    # `body:` here is `body~` with a literal needle, and `body~` reads the haystack by its true
    # byte length (Gori::SafeRegexp) rather than as a NUL-terminated string. A `CAST(… AS TEXT)
    # LIKE` would pass every other example in this file and fail only this one — silently, on
    # exactly the bodies a proxy for security work is pointed at.
    it "scans a body past an embedded NUL, like body~" do
      with_globals do
        with_store do |store|
          bin = captured(store, "bin.test", "/img", body_bytes: Bytes[0xFF, 0xFE, 0x00, 0x41, 0x42, 0x43])
          cm = Gori::Colormarker.load(store)
          cm.add("body:ABC", RED, FULL, "past-nul")
          cm.match(bin).not_nil!.name.should eq("past-nul")
        end
      end
    end

    # The bound, and it is a real one. A body is capped at CAPTURE by `Settings.capture_max`
    # (2 MiB by default), and resolving a screenful of those uncapped measured ~460 ms — half a
    # second of stall per screen on the render path. So a rule reads the first `BODY_SCAN_MAX`
    # bytes of each side, exactly as `Rules::RULE_PREVIEW_BODY_MAX` bounds the Rewriter preview,
    # and `advise` says so where a rule is written. Pinned in both directions.
    it "scans a bounded prefix of the body, and says where the bound is" do
      with_globals do
        with_store do |store|
          pad = "p" * Gori::Colormarker::BODY_SCAN_MAX
          near = captured(store, "acme.test", "/near", body: "needle-here#{pad}")
          far = captured(store, "acme.test", "/far", body: "#{pad}needle-here")
          cm = Gori::Colormarker.load(store)
          cm.add("body:needle-here", RED, FULL, "leak")
          cm.match(near).not_nil!.name.should eq("leak")
          cm.match(far).should be_nil # past the bound — the documented miss
          Gori::Colormarker.advise("body:needle-here").first
            .should contain("first #{Gori::Colormarker::BODY_SCAN_MAX // 1024} KiB")
        end
      end
    end

    # The OTHER bound, and the one an operator is likeliest to assume away. `body:` here scans
    # the bytes AS STORED, which are the wire bytes: a gzipped response containing "secret" does
    # not contain the literal "secret", so no scan can find it. That is the exact opposite of an
    # EXTRACT rule, which decodes first (`bindings_proxy_extract_spec`: "reaches a token inside a
    # gzipped body") — so the two surfaces genuinely differ here, and only the docs can say it.
    it "does not reach a token inside a gzipped body, unlike an extract rule" do
      with_globals do
        with_store do |store|
          io = IO::Memory.new
          Compress::Gzip::Writer.open(io, &.write("csrf=SeCrEtToken".to_slice))
          zipped = captured(store, "acme.test", "/gz", body_bytes: io.to_slice)
          plain = captured(store, "acme.test", "/plain", body: "csrf=SeCrEtToken")
          cm = Gori::Colormarker.load(store)
          cm.add("body:secrettoken", RED, FULL, "leak")
          cm.match(plain).not_nil!.name.should eq("leak")
          cm.match(zipped).should be_nil
        end
      end
    end

    # The other half of the store tier: the fields History has and a `FlowRow` cannot answer.
    # Every one of these used to be REFUSED at creation as an unknown field.
    it "answers header:, size: and url: terms against the store" do
      with_globals do
        with_store do |store|
          flow = captured(store, "acme.test", "/login", body: "x=1",
            head: "POST /login HTTP/1.1\r\nHost: acme.test\r\nX-Trace: abc123\r\n\r\n")
          other = captured(store, "cdn.test", "/logo.png", body: "y=2")
          cm = Gori::Colormarker.load(store)
          cm.add("header:x-trace", RED, FULL, "traced")
          cm.match(flow).not_nil!.name.should eq("traced")
          cm.match(other).should be_nil
        end
      end
    end

    # A store-tier answer is memoised per {rule, flow}, and a row whose bytes CHANGE has to drop
    # it — the pending row genuinely had no response body to match. History calls `forget` at the
    # same moment it drops its own per-row colour memo.
    it "re-asks a store-tier rule after `forget`" do
      with_globals do
        with_store do |store|
          id = store.insert_flow(Gori::Store::CapturedRequest.new(
            created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
            method: "GET", target: "/slow", http_version: "HTTP/1.1",
            head: "GET /slow HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice, body: nil))
          pending = store.flow_row(id).not_nil!
          cm = Gori::Colormarker.load(store)
          cm.add("body:landed", RED, FULL, "late")
          cm.match(pending).should be_nil # no response body yet — a real "no"

          store.update_response(Gori::Store::CapturedResponse.new(
            flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\n\r\n".to_slice,
            body: "it landed here".to_slice))
          settled = store.flow_row(id).not_nil!
          cm.match(settled).should be_nil # still the cached "no"
          cm.forget(id)
          cm.match(settled).not_nil!.name.should eq("late")
        end
      end
    end

    # The tier split is a property of the CONDITION, and the row tier must stay exactly what it
    # was: no store access, and `needs_store?` false so History never even calls `prefetch`.
    it "keeps an addressing-only rule in the row tier" do
      Gori::Colormarker.row_answerable?("host:acme status:5xx -method:GET").should be_true
      Gori::Colormarker.row_answerable?("login").should be_true # bare free text names no field
      Gori::Colormarker.row_answerable?("body:secret").should be_false
      Gori::Colormarker.row_answerable?("host~^api\\.").should be_false # only QL implements ~
      Gori::Colormarker.row_answerable?("size:>1k").should be_false
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:acme", RED, FULL)
          cm.needs_store?.should be_false
        end
      end
    end

    # An in-flight row has no status yet. This is the case History's per-row memo has to evict
    # on `:updated`, so the engine half of it is pinned here.
    it "does not match a status rule until the response lands" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("status:>=500", RED, FULL)
          cm.match(row(status: nil)).should be_nil
          cm.match(row(status: 503)).should_not be_nil
        end
      end
    end

    # The Interceptor gates WebSocket subjects behind an explicit un-negated `proto:ws`, because
    # HOLDING a socket carrying tens of messages a second is unrecoverable. PAINTING one is not,
    # so that gate must not be copied over: `host:acme` colours a WS row like any other.
    it "paints a WebSocket row without an explicit proto:ws" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:acme", RED, FULL)
          ws = row(status: 101, content_type: nil)
          cm.match(ws, Gori::Proto::Kind::Ws).should_not be_nil
        end
      end
    end
  end

  describe "validation" do
    # `InterceptFilter.new` never raises, so every refusal has to be made explicitly — and each
    # of these would otherwise fail SILENTLY rather than loudly.
    it "refuses a condition that would paint every row" do
      Gori::Colormarker.unusable_reason("").should eq("enter a condition")
      # a term with an empty value is DROPPED, and an emptied query matches everything
      Gori::Colormarker.unusable_reason("host:").should eq("this condition matches every flow")
      Gori::Colormarker.unusable_reason("host:acme").should be_nil
    end

    # Every one of these was refused as an "unknown field" until the store tier existed. They are
    # History QL fields, which is exactly why an operator reaches for them, and a colour rule now
    # answers all of them.
    it "accepts every field History's filter bar has" do
      Gori::QL::FIELDS.each do |field|
        # A value each field actually ACCEPTS: a term QL drops (`proto:x`) folds the condition to
        # match-all, and being refused for THAT is a different — and correct — answer.
        value = case field
                when "status", "size", "reqsize", "respsize", "dur" then "1"
                when "proto"                                        then "ws"
                when "stub"                                         then "true"
                else                                                     "x"
                end
        Gori::Colormarker.unusable_reason("#{field}:#{value}").should be_nil
      end
      Gori::Colormarker.unknown_fields("host:a AND size:1 OR dur:2").should be_empty
    end

    # An unknown field still has to be refused, and for the reason it always did: BOTH compilers
    # free-text the whole token, so `hsot:evil.com` becomes a literal substring search over
    # method/host/target and the rule never fires, with no error anywhere.
    it "refuses a field neither compiler implements" do
      reason = Gori::Colormarker.unusable_reason("hsot:evil.com")
      reason.not_nil!.should contain("unknown field `hsot:`")
      Gori::Colormarker.unknown_fields("host:a hsot:b flag:c").should eq(["hsot", "flag"])
      # `~` IS a separator now, so an unknown field is caught on that side too — and a known one
      # is not mistaken for one.
      Gori::Colormarker.unknown_fields("host~x").should be_empty
      Gori::Colormarker.unknown_fields("hsot~x").should eq(["hsot"])
    end

    # QL turns an uncompilable `~` pattern into a never-match clause on purpose: for a QUERY that
    # is an empty result an operator can see. For a RULE it is a colour that never appears, with
    # nothing to look at — so it is refused where it is written instead.
    it "refuses a regex that cannot compile" do
      Gori::Colormarker.unusable_reason("body~[bad").not_nil!.should contain("not a valid regex")
      Gori::Colormarker.unusable_reason("body~[a-z]+").should be_nil
    end

    it "refuses to create a rule with an unusable condition" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("", RED, FULL).should be_false
          cm.add("host:", RED, FULL).should be_false
          cm.rules.should be_empty
        end
      end
    end

    # The parser is deliberately MORE tolerant than creation: `InterceptFilter::EMPTY` matches
    # everything, so an empty condition on disk is a legal (if unwise) "paint every row" rule,
    # and dropping it would delete a rule its author can see in their own file.
    it "preserves an empty condition already on disk" do
      with_globals do
        with_store do |store|
          Gori::Settings.colormarker_rules = [
            Gori::Settings::ColormarkerRule.new(1_i64, true, "everything", "", "red", "full"),
          ]
          cm = Gori::Colormarker.load(store)
          cm.rules.size.should eq(1)
          cm.match(row).not_nil!.name.should eq("everything")
        end
      end
    end
  end

  describe "rule scope" do
    it "toggles a global rule per project without touching its default" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:acme", RED, FULL, scope: GLOBAL)
          id = cm.rules.first.id

          cm.toggle(id, GLOBAL).should be_true
          cm.rules.first.enabled?.should be_false
          cm.rules.first.overridden?.should be_true
          # the LIBRARY still says on — only this project disagrees
          Gori::Settings.colormarker_rules.first.enabled.should be_true
          store.colormarker_overrides[id].should be_false

          # Toggling back AGREES with the default, so the override is dropped rather than
          # pinned — this project follows a later change to the default again.
          cm.toggle(id, GLOBAL).should be_true
          cm.rules.first.enabled?.should be_true
          cm.rules.first.overridden?.should be_false
          store.colormarker_overrides.should be_empty
        end
      end
    end

    it "flips the global default for projects that have not overridden it" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:acme", RED, FULL, scope: GLOBAL)
          id = cm.rules.first.id
          cm.toggle_default(id).should be_true
          cm.rules.first.enabled?.should be_false
          cm.rules.first.overridden?.should be_false
          cm.active?.should be_false

          # A project rule has no default to flip — and it takes the SCOPE to know that. Both
          # stores count ids from 1, so this project rule is ALSO #1: a bare-id version would
          # find the global rule instead and flip it in every other project, reporting success.
          cm.add("host:x", BLUE, FULL)
          local = cm.rules.last
          local.scope.project?.should be_true
          local.id.should eq(id) # the collision this guard exists for
          cm.toggle_default(local.id, local.scope).should be_false
          cm.rules.first.enabled?.should be_false # the global default was not touched again
        end
      end
    end

    it "moves a rule between scopes, keeping its fields and its state here" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:acme", BLUE, STRIP, "local")
          rule = cm.rules.first
          cm.set_scope(rule, GLOBAL).should be_true

          store.color_rules.should be_empty
          Gori::Settings.colormarker_rules.size.should eq(1)
          moved = cm.rules.first
          moved.scope.should eq(GLOBAL)
          moved.name.should eq("local")
          moved.color.should eq(BLUE)
          moved.style.should eq(STRIP)
          # the same scope is not a move
          cm.set_scope(moved, GLOBAL).should be_false
        end
      end
    end

    it "drops this project's override when the global rule is deleted" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:acme", RED, FULL, scope: GLOBAL)
          id = cm.rules.first.id
          cm.toggle(id, GLOBAL).should be_true
          store.colormarker_overrides.should_not be_empty

          cm.remove(id, GLOBAL).should be_true
          store.colormarker_overrides.should be_empty
        end
      end
    end

    # Order is the rule set's MEANING here, not a tiebreak — so the assertion is not "the list
    # reordered" but "a different rule now paints the row".
    it "reorders within a scope, changing which rule wins" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:acme", RED, FULL, "first")
          cm.add("host:acme", BLUE, FULL, "second")
          cm.match(row).not_nil!.name.should eq("first")

          second = cm.rules.last
          cm.move(second.id, -1).should be_true
          cm.match(row).not_nil!.name.should eq("second")
          # an edge of its own block does not move
          cm.move(second.id, -1).should be_false
        end
      end
    end

    # `Store#move_color_rule` returned Nil, so `gori run colormarker move` and MCP
    # `move_color_rule` printed a successful reorder for a rolled-back write while their GLOBAL
    # branches reported PROJECT_BUSY — i.e. told the operator a different rule paints the row
    # than actually does. It answers whether the write COMMITTED now, and false also covers
    # "nothing moved", which is what both surfaces already had to distinguish.
    it "answers whether the project reorder actually landed" do
      with_store do |store|
        a = store.insert_color_rule("host:a", "red", FULL, "a")
        b = store.insert_color_rule("host:b", "blue", FULL, "b")
        store.move_color_rule(b, -1).should be_true
        store.color_rules.map(&.name).should eq(["b", "a"])
        # an edge of the list and an id that is not there both mean "nothing moved"
        store.move_color_rule(b, -1).should be_false
        store.move_color_rule(a, 1).should be_false
        store.move_color_rule(a + b + 99, -1).should be_false
      end
    end

    it "never reorders across the scope boundary" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:a", RED, FULL, scope: GLOBAL)
          cm.add("host:b", BLUE, FULL)
          # the only global rule cannot move down into the project block
          cm.move(cm.rules.first.id, 1, GLOBAL).should be_false
          cm.rules.map(&.scope).should eq([GLOBAL, Gori::Store::RuleScope::Project])
        end
      end
    end
  end

  describe "the render-path contract" do
    # The performance claim, made testable: `InterceptFilter.new` walks FilterAst, and doing
    # that once per row per FRAME is the failure this design exists to prevent. A future
    # refactor that moves compilation onto the render path must fail HERE, not in a frame
    # budget nobody measures.
    it "compiles each condition once per edit, not once per match" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:acme", RED, FULL)
          rev = cm.revision
          200.times { cm.match(row) }
          cm.revision.should eq(rev) # matching neither recompiles nor re-snapshots
        end
      end
    end

    # `reload` rides the TUI's data_version poll (~1/sec during capture). If an unchanged rule
    # set bumped the revision, History would throw away its per-row memo every tick.
    it "does not bump the revision when nothing changed" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.add("host:acme", RED, FULL)
          rev = cm.revision
          5.times { cm.reload }
          cm.revision.should eq(rev)
          cm.add("host:other", BLUE, FULL)
          cm.revision.should be > rev
        end
      end
    end

    it "reports whether History must reserve its swatch column" do
      with_globals do
        with_store do |store|
          cm = Gori::Colormarker.load(store)
          cm.strip_active?.should be_false
          cm.add("host:acme", RED, FULL)
          cm.strip_active?.should be_false # a full-row rule needs no column
          cm.add("host:cdn", BLUE, STRIP)
          cm.strip_active?.should be_true
          cm.toggle(cm.rules.last.id).should be_true
          cm.strip_active?.should be_false # disabling the only strip rule releases it
        end
      end
    end
  end

  describe ".summary" do
    it "renders a rule the same way every surface does" do
      unnamed = Gori::Store::ColorRule.new(1_i64, true, "status:5xx", RED, FULL)
      Gori::Colormarker.summary(unnamed).should eq("red full: status:5xx")
      named = Gori::Store::ColorRule.new(2_i64, true, "host:cdn", YELLOW, STRIP, "noise")
      Gori::Colormarker.summary(named).should eq("yellow strip: noise — host:cdn")
    end
  end
end
