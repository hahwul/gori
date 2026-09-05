require "../spec_helper"
require "../support/mcp_harness"

describe Gori::MCP::Server do
  describe "colormarker rules" do
    it "creates, lists, toggles, reorders, and deletes a colour rule" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_color_rule","arguments":{"when":"status:>=500","color":"red","style":"full","name":"prod 5xx"}}})
        payload = mcp_tool_payload(mcp_drive(store, create)[0])
        id = payload["id"].as_i64
        id.should_not eq(0)
        payload["color"].as_s.should eq("red")
        payload["style"].as_s.should eq("full")
        # `status:` carries an advisory (a pending flow has no status yet) — non-fatal, and
        # the only channel there is, since an InterceptFilter cannot fail to compile.
        payload["notes"][0].as_s.should contain("no response yet")

        listed = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_color_rules"}}))[0])
        listed["count"].as_i64.should eq(1)
        rule = listed["rules"][0]
        rule["when"].as_s.should eq("status:>=500")
        rule["scope"].as_s.should eq("project")
        rule["enabled"].as_bool.should be_true
        rule["name"].as_s.should eq("prod 5xx")

        toggle = %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"set_color_rule_enabled","arguments":{"id":#{id},"enabled":false}}})
        mcp_tool_payload(mcp_drive(store, toggle)[0])["enabled"].as_bool.should be_false
        store.color_rules[0].enabled?.should be_false

        # Reorder is a SEMANTIC edit here — the first enabled match paints the row — so it is a
        # tool rather than a TUI-only affordance.
        second = %({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"create_color_rule","arguments":{"when":"method:DELETE","color":"orange"}}})
        id2 = mcp_tool_payload(mcp_drive(store, second)[0])["id"].as_i64
        mv = %({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"move_color_rule","arguments":{"id":#{id2},"direction":"up"}}})
        mcp_tool_payload(mcp_drive(store, mv)[0])["moved"].as_s.should eq("up")
        store.color_rules.map(&.id).should eq([id2, id])
        # …and the edge is refused rather than silently doing nothing.
        mcp_drive(store, %({"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"move_color_rule","arguments":{"id":#{id2},"direction":"up"}}}))[0]["result"]["isError"].as_bool.should be_true

        del = %({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"delete_color_rule","arguments":{"id":#{id}}}})
        mcp_tool_payload(mcp_drive(store, del)[0])["deleted"].as_bool.should be_true
        store.color_rules.map(&.id).should eq([id2])
      end
    end

    # Every refusal here names a rule that would otherwise fail SILENTLY: an InterceptFilter
    # never fails to compile, so there is no parse error to lean on.
    it "refuses conditions and enum values that would never do what the caller meant" do
      with_store do |store|
        {
          %({"when":"host:"}),      # a term with an empty value is dropped ⇒ matches everything
          %({"when":"szie:>1000"}), # a field neither compiler implements ⇒ free-texted, never fires
          %({"when":"body~[bad"}),  # a regex that will not compile ⇒ a colour that never appears
          %({"when":"a","color":"chartreuse"}),
          %({"when":"a","style":"sideways"}),
        }.each_with_index do |args, i|
          call = %({"jsonrpc":"2.0","id":#{i + 1},"method":"tools/call","params":{"name":"create_color_rule","arguments":#{args}}})
          mcp_drive(store, call)[0]["result"]["isError"].as_bool.should be_true
        end
        store.color_rules.should be_empty # nothing was persisted by any of them
      end
    end

    it "manages custom colours, which a rule can then reference on any surface" do
      before = Gori::Settings.colormarker_colors
      begin
        Gori::Settings.colormarker_colors = [] of Gori::Settings::ColormarkerColor
        with_store do |store|
          create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_custom_color","arguments":{"name":"Coral","hex":"ff6b6b"}}})
          payload = mcp_tool_payload(mcp_drive(store, create)[0])
          payload["name"].as_s.should eq("coral") # name + hex normalised
          payload["hex"].as_s.should eq("#ff6b6b")

          listed = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_custom_colors"}}))[0])
          listed["count"].as_i64.should eq(1)
          listed["colors"][0]["name"].as_s.should eq("coral")

          # A rule may now paint with the custom name — validation accepts it where it once
          # refused any non-built-in word.
          rule = %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"create_color_rule","arguments":{"when":"host:h.test","color":"coral"}}})
          mcp_tool_payload(mcp_drive(store, rule)[0])["color"].as_s.should eq("coral")

          # A built-in word and a duplicate are both refused, said out loud.
          mcp_drive(store, %({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"create_custom_color","arguments":{"name":"red","hex":"#000000"}}}))[0]["result"]["isError"].as_bool.should be_true
          mcp_drive(store, %({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"create_custom_color","arguments":{"name":"coral","hex":"#000000"}}}))[0]["result"]["isError"].as_bool.should be_true

          # Editing in place. `Settings.update_colormarker_color` had exactly one caller (the
          # TUI's colour editor), so an agent could only delete + re-add — which is a different
          # action: between the two, every rule naming the colour paints a fallback hue.
          recolour = %({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"update_custom_color","arguments":{"name":"coral","hex":"#123456"}}})
          recoloured = mcp_tool_payload(mcp_drive(store, recolour)[0])
          recoloured["name"].as_s.should eq("coral") # a hex-only edit does not rename
          recoloured["hex"].as_s.should eq("#123456")
          recoloured["renamed_from"]?.should be_nil

          rename = %({"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"update_custom_color","arguments":{"name":"coral","new_name":"Salmon"}}})
          renamed = mcp_tool_payload(mcp_drive(store, rename)[0])
          renamed["name"].as_s.should eq("salmon")
          renamed["hex"].as_s.should eq("#123456") # the unnamed half is carried over, not reset
          renamed["renamed_from"].as_s.should eq("coral")

          # An unknown colour, a no-op call and a built-in name are all refused rather than
          # silently doing nothing.
          mcp_drive(store, %({"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"update_custom_color","arguments":{"name":"nope","hex":"#000000"}}}))[0]["result"]["isError"].as_bool.should be_true
          mcp_drive(store, %({"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"update_custom_color","arguments":{"name":"salmon"}}}))[0]["result"]["isError"].as_bool.should be_true
          mcp_drive(store, %({"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"update_custom_color","arguments":{"name":"salmon","new_name":"green"}}}))[0]["result"]["isError"].as_bool.should be_true

          del = %({"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"delete_custom_color","arguments":{"name":"salmon"}}})
          mcp_tool_payload(mcp_drive(store, del)[0])["deleted"].as_bool.should be_true
          Gori::Settings.colormarker_colors.should be_empty
        end
      ensure
        Gori::Settings.colormarker_colors = before
      end
    end

    it "previews without creating, and separates what MATCHES from what would be PAINTED" do
      with_store do |store|
        mcp_drive(store, %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_color_rule","arguments":{"when":"host:h.test","color":"blue"}}}))
        pv = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"preview_color_rule","arguments":{"when":"body:secret"}}}))[0])
        pv["would_match"].as_i64.should eq(0) # nothing captured in this store to match
        pv["would_paint"].as_i64.should eq(0)
        # The note is now the OPPOSITE claim: `body:` works here, and reaches further than the
        # same term in the filter bar does.
        pv["notes"][0].as_s.should contain("scans here rather than reading the text index")
        pv["notes"][0].as_s.should contain("as CAPTURED") # ...and says what that costs
        store.color_rules.size.should eq(1)               # the preview created nothing
      end
    end

    # The scope half, and the agree-again rule: an override exists ONLY while it differs.
    it "creates a GLOBAL colour rule, overrides it per project, and refuses an unknown scope" do
      before = Gori::Settings.colormarker_rules
      counter = Gori::Settings.colormarker_next_rule_id
      begin
        Gori::Settings.colormarker_rules = [] of Gori::Settings::ColormarkerRule
        Gori::Settings.colormarker_next_rule_id = 1_i64
        with_store do |store|
          create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_color_rule","arguments":{"when":"host:cdn","color":"blue","style":"strip","scope":"global"}}})
          payload = mcp_tool_payload(mcp_drive(store, create)[0])
          payload["scope"].as_s.should eq("global")
          id = payload["id"].as_i64
          store.color_rules.should be_empty # not a project row
          Gori::Settings.colormarker_rules.size.should eq(1)

          listed = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_color_rules"}}))[0])
          rule = listed["rules"][0]
          rule["scope"].as_s.should eq("global")
          rule["overridden"].as_bool.should be_false
          rule["default_enabled"].as_bool.should be_true

          # Disabling WITHOUT `everywhere` is this project's override — the library still says on.
          off = %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"set_color_rule_enabled","arguments":{"id":#{id},"scope":"global","enabled":false}}})
          mcp_tool_payload(mcp_drive(store, off)[0])["enabled"].as_bool.should be_false
          Gori::Settings.colormarker_rules.first.enabled.should be_true
          store.colormarker_overrides[id].should be_false

          # Setting it back to the library's OWN default drops the override rather than pinning
          # it, so this project keeps following a later change to that default.
          on = %({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"set_color_rule_enabled","arguments":{"id":#{id},"scope":"global","enabled":true}}})
          mcp_tool_payload(mcp_drive(store, on)[0])["enabled"].as_bool.should be_true
          store.colormarker_overrides.should be_empty

          # …and `everywhere` writes the default itself.
          everywhere = %({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"set_color_rule_enabled","arguments":{"id":#{id},"scope":"global","enabled":false,"everywhere":true}}})
          mcp_tool_payload(mcp_drive(store, everywhere)[0])["everywhere"].as_bool.should be_true
          Gori::Settings.colormarker_rules.first.enabled.should be_false

          # An id that exists in the OTHER scope is not this rule.
          mcp_drive(store, %({"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"delete_color_rule","arguments":{"id":#{id}}}}))[0]["result"]["isError"].as_bool.should be_true
          Gori::Settings.colormarker_rules.size.should eq(1)

          # A typo'd scope is REFUSED, never clamped to project.
          mcp_drive(store, %({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"delete_color_rule","arguments":{"id":#{id},"scope":"globl"}}}))[0]["result"]["isError"].as_bool.should be_true

          # Re-override, then delete: the disagreement dies with the rule.
          mcp_drive(store, %({"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"set_color_rule_enabled","arguments":{"id":#{id},"scope":"global","enabled":true}}}))
          store.colormarker_overrides.should_not be_empty
          del = %({"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"delete_color_rule","arguments":{"id":#{id},"scope":"global"}}})
          mcp_tool_payload(mcp_drive(store, del)[0])["deleted"].as_bool.should be_true
          Gori::Settings.colormarker_rules.should be_empty
          store.colormarker_overrides.should be_empty
        end
      ensure
        Gori::Settings.colormarker_rules = before
        Gori::Settings.colormarker_next_rule_id = counter
      end
    end
  end

  describe "match&replace rules" do
    it "creates, lists, toggles, and deletes a rule" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_rule","arguments":{"pattern":"secret","replacement":"REDACTED","target":"response","part":"body"}}})
        id = mcp_tool_payload(mcp_drive(store, create)[0])["id"].as_i64
        id.should_not eq(0)

        listed = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_rules"}}))[0])
        listed["count"].as_i64.should eq(1)
        rule = listed["rules"][0]
        rule["pattern"].as_s.should eq("secret")
        rule["target"].as_s.should eq("response")
        rule["part"].as_s.should eq("body")
        rule["enabled"].as_bool.should be_true

        toggle = %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"set_rule_enabled","arguments":{"id":#{id},"enabled":false}}})
        mcp_tool_payload(mcp_drive(store, toggle)[0])["enabled"].as_bool.should be_false
        store.match_rules[0].enabled?.should be_false

        del = %({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"delete_rule","arguments":{"id":#{id}}}})
        mcp_tool_payload(mcp_drive(store, del)[0])["deleted"].as_bool.should be_true
        store.match_rules.should be_empty
      end
    end

    # Presets (#821): list_rule_presets is read-only; create_rule_from_preset installs the
    # catalog's rules through the same insert path create_rule uses, so they are ordinary rows.
    it "lists presets and installs one as ordinary Match & Replace rules" do
      with_store do |store|
        presets = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_rule_presets"}}))[0])
        presets.as_a.map { |p| p["key"].as_s }.should contain("remove-csp")

        add = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"create_rule_from_preset","arguments":{"preset":"remove-csp"}}})
        res = mcp_tool_payload(mcp_drive(store, add)[0])
        res["created"].as_i64.should eq(2)
        res["ids"].as_a.size.should eq(2)
        store.match_rules.size.should eq(2)
        store.match_rules.all?(&.op.remove_header?).should be_true
        # And it shows up in list_rules like any hand-authored rule.
        listed = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_rules"}}))[0])
        listed["count"].as_i64.should eq(2)
      end
    end

    it "refuses an unknown preset key without persisting anything" do
      with_store do |store|
        bad = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_rule_from_preset","arguments":{"preset":"nope"}}})
        resp = mcp_drive(store, bad)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("INVALID_ARGUMENT")
        resp["structuredContent"]["field"].as_s.should eq("preset")
        store.match_rules.should be_empty
      end
    end

    it "gates create_rule_from_preset in read-only mode but keeps list_rule_presets" do
      with_store do |store|
        list = mcp_drive(store, %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_rule_presets"}}), allow_actions: false)[0]
        list["result"]["isError"]?.try(&.as_bool).should_not be_true
        add = mcp_drive(store, %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"create_rule_from_preset","arguments":{"preset":"remove-csp"}}}), allow_actions: false)[0]
        add["result"]["isError"].as_bool.should be_true
        store.match_rules.should be_empty
      end
    end

    # The scope half: a global rule lives in settings.json and applies in EVERY project, so
    # every by-id tool takes a `scope` alongside the id — the two stores number independently.
    it "creates a GLOBAL rule, overrides it per project, and refuses an unknown scope" do
      before = Gori::Settings.rewriter_rules
      counter = Gori::Settings.rewriter_next_rule_id
      begin
        Gori::Settings.rewriter_rules = [] of Gori::Settings::RewriterRule
        Gori::Settings.rewriter_next_rule_id = 1_i64
        with_store do |store|
          create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_rule","arguments":{"pattern":"Server: nginx","replacement":"Server: gori","target":"response","scope":"global"}}})
          payload = mcp_tool_payload(mcp_drive(store, create)[0])
          payload["scope"].as_s.should eq("global")
          id = payload["id"].as_i64
          store.match_rules.should be_empty # not a project row
          Gori::Settings.rewriter_rules.size.should eq(1)

          listed = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_rules"}}))[0])
          rule = listed["rules"][0]
          rule["scope"].as_s.should eq("global")
          rule["enabled"].as_bool.should be_true
          rule["overridden"].as_bool.should be_false
          rule["default_enabled"].as_bool.should be_true

          # Disabling WITHOUT `everywhere` is this project's override — the library still says on.
          off = %({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"set_rule_enabled","arguments":{"id":#{id},"scope":"global","enabled":false}}})
          mcp_tool_payload(mcp_drive(store, off)[0])["enabled"].as_bool.should be_false
          Gori::Settings.rewriter_rules.first.enabled.should be_true
          store.rewriter_overrides[id].should be_false
          again = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_rules"}}))[0])
          again["rules"][0]["overridden"].as_bool.should be_true
          again["rules"][0]["default_enabled"].as_bool.should be_true

          # …and with it, the default itself.
          everywhere = %({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"set_rule_enabled","arguments":{"id":#{id},"scope":"global","enabled":false,"everywhere":true}}})
          mcp_tool_payload(mcp_drive(store, everywhere)[0])["everywhere"].as_bool.should be_true
          Gori::Settings.rewriter_rules.first.enabled.should be_false

          # An id that exists in the OTHER scope is not this rule.
          missing = %({"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"delete_rule","arguments":{"id":#{id}}}})
          mcp_drive(store, missing)[0]["result"]["isError"].as_bool.should be_true
          Gori::Settings.rewriter_rules.size.should eq(1)

          # A typo'd scope is REFUSED, never clamped to project — clamping would report
          # success for an edit the caller meant to make everywhere.
          bad = %({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"delete_rule","arguments":{"id":#{id},"scope":"globl"}}})
          mcp_drive(store, bad)[0]["result"]["isError"].as_bool.should be_true

          del = %({"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"delete_rule","arguments":{"id":#{id},"scope":"global"}}})
          mcp_tool_payload(mcp_drive(store, del)[0])["deleted"].as_bool.should be_true
          Gori::Settings.rewriter_rules.should be_empty
          store.rewriter_overrides.should be_empty # the disagreement dies with the rule
        end
      ensure
        Gori::Settings.rewriter_rules = before
        Gori::Settings.rewriter_next_rule_id = counter
      end
    end

    it "rejects an invalid target on create (persists nothing)" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_rule","arguments":{"pattern":"x","target":"sideways"}}})
        resp = mcp_drive(store, call)[0]
        resp["result"]["isError"].as_bool.should be_true
        store.match_rules.should be_empty
      end
    end

    # The same "persists nothing" contract, on the EXTRACT tools. It did not hold: the rule
    # was written first and `enabled` was read after, so a rejected call left a live, ENABLED
    # extract rule behind — already observing every matching response and binding its name for
    # Match&Replace injection. `bool_arg` raises on a non-boolean, and clients that stringify
    # booleans (`"enabled": "yes"`) are exactly what its own comment warns about.
    it "rejects a non-boolean 'enabled' on extract create WITHOUT leaving the rule behind" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_extract_rule",) +
               %("arguments":{"name":"SESSION","kind":"cookie","selector":"sid","enabled":"yes"}}})
        resp = mcp_drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        # The caller's argument, so INVALID_ARGUMENT — not the catch-all's INTERNAL.
        resp["structuredContent"]["error_code"].as_s.should eq("INVALID_ARGUMENT")
        store.extract_rules.should be_empty
      end
    end

    it "rejects a non-boolean 'enabled' on extract update WITHOUT committing the other fields" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_extract_rule",) +
                 %("arguments":{"name":"SESSION","kind":"cookie","selector":"sid"}}})
        id = mcp_tool_payload(mcp_drive(store, create)[0])["id"].as_i64
        call = %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"update_extract_rule",) +
               %("arguments":{"id":#{id},"selector":"other","enabled":"nope"}}})
        resp = mcp_drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("INVALID_ARGUMENT")
        store.extract_rules.first.selector.should eq("sid") # unchanged
      end
    end

    it "rejects an unrecognized match kind instead of silently coercing to literal" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_rule","arguments":{"pattern":"x","match":"regex-ignorecase"}}})
        resp = mcp_drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("INVALID_ARGUMENT")
        resp["structuredContent"]["field"].as_s.should eq("match")
        store.match_rules.should be_empty # not coerced into a stray literal rule
      end
    end

    it "still accepts the valid regex/literal match kinds" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_rule","arguments":{"pattern":"a\\\\d+","replacement":"x","match":"regex"}}})
        mcp_tool_payload(mcp_drive(store, call)[0])["match"].as_s.should eq("regex")
        store.match_rules[0].match_kind.regex?.should be_true
      end
    end

    it "creates a rule already disabled (atomic) with enabled:false" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_rule","arguments":{"pattern":"x","enabled":false}}})
        mcp_tool_payload(mcp_drive(store, create)[0])["enabled"].as_bool.should be_false
        store.match_rules[0].enabled?.should be_false # never live between create and disable
      end
    end

    it "updates an existing rule's pattern/part in place" do
      with_store do |store|
        id = store.insert_rule(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "old", "")
        upd = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"update_rule","arguments":{"id":#{id},"pattern":"new","part":"body"}}})
        mcp_tool_payload(mcp_drive(store, upd)[0])["updated"].as_bool.should be_true
        r = store.match_rules[0]
        r.pattern.should eq("new")
        r.part.body?.should be_true
        r.target.request?.should be_true # unchanged field preserved
      end
    end

    it "previews a rule's match count without creating it" do
      with_store do |store|
        mcp_seed_flow(store, "auth.test", "GET", "/x", 200) # request head has "auth.test"
        mcp_seed_flow(store, "other.test", "GET", "/y", 200)
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"preview_rule","arguments":{"pattern":"auth.test","target":"request","part":"head"}}})
        p = mcp_tool_payload(mcp_drive(store, call)[0])
        p["would_match"].as_i.should eq(1)
        p["scanned"].as_i.should eq(2)
        store.match_rules.should be_empty # preview creates nothing
      end
    end

    it "rejects an uncompilable regex in preview_rule instead of a fake 0-match result" do
      with_store do |store|
        call = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"preview_rule","arguments":{"pattern":"[invalid\(regex","match":"regex"}}})
        resp = mcp_drive(store, call)[0]["result"]
        resp["isError"].as_bool.should be_true
        resp["structuredContent"]["error_code"].as_s.should eq("INVALID_ARGUMENT")
        resp["structuredContent"]["field"].as_s.should eq("pattern")
        store.match_rules.should be_empty
      end
    end

    it "reports an error for delete/toggle of an unknown rule id" do
      with_store do |store|
        del = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"delete_rule","arguments":{"id":999}}})
        mcp_drive(store, del)[0]["result"]["isError"].as_bool.should be_true
      end
    end

    it "gates rule write tools in read-only mode but keeps list_rules" do
      with_store do |store|
        create = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"create_rule","arguments":{"pattern":"x"}}})
        mcp_drive(store, create, allow_actions: false)[0]["result"]["isError"].as_bool.should be_true
        store.match_rules.should be_empty

        listed = mcp_tool_payload(mcp_drive(store, %({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_rules"}}), allow_actions: false)[0])
        listed["count"].as_i64.should eq(0)
      end
    end
  end
end
