require "../spec_helper"
require "file_utils"

# The GLOBAL rewriter and colormarker rule libraries are the only two settings sections that are
# not one operator decision: each holds a whole rule LIST plus the `next_rule_id` counter that
# numbers it, in ONE top-level key. `Settings.save`'s 3-way merge works at that key, so two gori
# processes each adding a rule had both "changed the section" — the later writer's whole list won
# and the other's rule was gone. Both had also minted from the same counter, so the two rules
# could carry the SAME id, and a project store's `rewriter_overrides` / `colormarker_overrides`
# are keyed by exactly that id: the loser's override silently reattaches to the winner's rule, in
# a database neither process opens again.
#
# Two halves fix that, and this file pins them apart, because either alone makes the obvious
# assertion pass:
#
#   * the RE-READ (`reload_rewriter_from_disk` / `reload_colormarker_from_disk`, run by every
#     CRUD before it touches anything) is the only thing that can stop the id collision — an id
#     already handed out by a peer is not recoverable after the fact;
#   * the MERGE INSIDE the section (`merge_rule_section`) is the only thing that covers the
#     window between that re-read and the write landing, which is where a peer's rule is lost
#     even when the counter is fresh.
#
# So the two "only X fixes this" examples below are staged differently on purpose: the first goes
# through the real CRUD, the second stages memory directly and calls `save`, which is the state a
# CRUD is in at the moment the peer lands.
private def with_rule_home(&)
  dir = File.tempname("gori-rule-merge")
  Dir.mkdir_p(dir)
  prev_home = ENV["GORI_HOME"]?
  prev_cfg = ENV["GORI_CONFIG"]?
  prev_override = Gori::Settings.path_override
  prev_rw = Gori::Settings.rewriter_rules
  prev_rw_next = Gori::Settings.rewriter_next_rule_id
  prev_cm = Gori::Settings.colormarker_rules
  prev_cm_next = Gori::Settings.colormarker_next_rule_id
  prev_colors = Gori::Settings.colormarker_colors
  # Every example here hands `Settings.load` a file holding nothing BUT its own section, so the
  # load resets the rest to factory defaults. Put back the ones a later spec file would notice.
  prev_theme = Gori::Settings.theme
  prev_port = Gori::Settings.bind_port
  prev_env = Gori::Settings.env_vars
  prev_upstream = Gori::Settings.upstream_rules
  begin
    ENV["GORI_HOME"] = dir
    ENV.delete("GORI_CONFIG")
    Gori::Settings.path_override = nil
    Gori::Settings.rewriter_rules = [] of Gori::Settings::RewriterRule
    Gori::Settings.rewriter_next_rule_id = 1_i64
    Gori::Settings.colormarker_rules = [] of Gori::Settings::ColormarkerRule
    Gori::Settings.colormarker_next_rule_id = 1_i64
    Gori::Settings.colormarker_colors = [] of Gori::Settings::ColormarkerColor
    yield
  ensure
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    prev_cfg ? (ENV["GORI_CONFIG"] = prev_cfg) : ENV.delete("GORI_CONFIG")
    Gori::Settings.path_override = prev_override
    Gori::Settings.rewriter_rules = prev_rw
    Gori::Settings.rewriter_next_rule_id = prev_rw_next
    Gori::Settings.colormarker_rules = prev_cm
    Gori::Settings.colormarker_next_rule_id = prev_cm_next
    Gori::Settings.colormarker_colors = prev_colors
    Gori::Settings.theme = prev_theme
    Gori::Settings.bind_port = prev_port
    Gori::Settings.env_vars = prev_env
    Gori::Settings.upstream_rules = prev_upstream
    FileUtils.rm_rf(dir)
  end
end

# One rule spelled the way `serialize_rewriter` spells it — same fields, same order — so the
# fixtures below are files a peer gori could really have written, not a shape only this spec
# understands. A fixture in a private spelling would let the merge key on something the parser
# renumbers and still pass.
private def rw_entry(id : Int32, pattern : String) : String
  %({"id":#{id},"enabled":true,"name":"r#{id}","target":"request","part":"head",) +
    %("pattern":"#{pattern}","replacement":"v","op":"set_header","match_kind":"literal",) +
    %("host":"","body_file":""})
end

private def write_rewriter(next_id : Int32, entries : Array(String)) : Nil
  File.write(Gori::Settings.path,
    %({"rewriter":{"next_rule_id":#{next_id},"rules":[#{entries.join(",")}]}}))
end

private def rw_rule(id : Int64, pattern : String) : Gori::Settings::RewriterRule
  Gori::Settings::RewriterRule.new(id, true, "r#{id}", "request", "head",
    pattern, "v", "set_header", "literal", "", "")
end

private def disk_section(key : String) : JSON::Any
  JSON.parse(File.read(Gori::Settings.path))[key]
end

private def disk_rewriter_ids : Array(Int64)
  disk_section("rewriter")["rules"].as_a.map(&.["id"].as_i64)
end

private def disk_rewriter_patterns : Array(String)
  disk_section("rewriter")["rules"].as_a.map(&.["pattern"].as_s)
end

private def cm_entry(id : Int32, cond : String, color : String) : String
  %({"id":#{id},"enabled":true,"name":"c#{id}","when":"#{cond}",) +
    %("color":"#{color}","style":"full"})
end

private def write_colormarker(next_id : Int32, rules : Array(String),
                              colors : Array(String)? = nil) : Nil
  body = %("next_rule_id":#{next_id},"rules":[#{rules.join(",")}])
  body += %(,"colors":[#{colors.join(",")}]) if colors
  File.write(Gori::Settings.path, %({"colormarker":{#{body}}}))
end

private def cm_color(name : String, hex : String) : String
  %({"name":"#{name}","hex":"#{hex}"})
end

private def disk_colormarker_ids : Array(Int64)
  disk_section("colormarker")["rules"].as_a.map(&.["id"].as_i64)
end

private def disk_colormarker_color_names : Array(String)
  disk_section("colormarker")["colors"].as_a.map(&.["name"].as_s)
end

describe "Settings — the global rewriter section against a concurrent writer" do
  # ONLY the re-read fixes this one. The merge cannot: by the time it runs, both rules exist and
  # both claim id 5, and nothing in the two documents says which of them is the newcomer.
  it "does not mint an id a peer minted while this process held its snapshot" do
    with_rule_home do
      write_rewriter(5, (1..4).map { |i| rw_entry(i, "X-#{i}") })
      Gori::Settings.load
      Gori::Settings.rewriter_next_rule_id.should eq(5_i64) # the stale snapshot, spelled out

      # A second gori adds a rule and lands it. Only the file knows.
      write_rewriter(6, (1..5).map { |i| rw_entry(i, "X-#{i}") })

      id = Gori::Settings.add_rewriter_rule("request", "head", "X-Ours", "v",
        "set_header", "literal", "ours", "", "")
      id.should eq(6_i64) # 5 is the peer's rule's, and an id is never reused
      Gori::Settings.rewriter_rules.map(&.id).should eq([1_i64, 2_i64, 3_i64, 4_i64, 5_i64, 6_i64])
    end
  end

  # The other half of the audit repro: the peer's rule is still there afterwards, and it is still
  # THEIR rule (the pattern proves the id was not quietly reused for ours).
  it "keeps the peer's rule when this process adds one" do
    with_rule_home do
      write_rewriter(5, (1..4).map { |i| rw_entry(i, "X-#{i}") })
      Gori::Settings.load
      write_rewriter(6, (1..5).map { |i| rw_entry(i, "X-#{i}") })

      Gori::Settings.add_rewriter_rule("request", "head", "X-Ours", "v",
        "set_header", "literal", "ours", "", "").should eq(6_i64)

      disk_rewriter_ids.should eq([1_i64, 2_i64, 3_i64, 4_i64, 5_i64, 6_i64])
      disk_rewriter_patterns.should eq(["X-1", "X-2", "X-3", "X-4", "X-5", "X-Ours"])
      disk_section("rewriter")["next_rule_id"].as_i64.should eq(7_i64)
    end
  end

  # ONLY the merge fixes this one. Memory is staged directly rather than through the CRUD because
  # the peer has to land AFTER the re-read and BEFORE the write — the window no re-read can
  # close, and the state a CRUD is in while it is inside `save`.
  #
  # All four dispositions in one example, because they are decided together: our edit beats
  # disk, our delete beats disk still holding the rule, an untouched rule follows the peer's
  # edit, and both adds survive.
  it "reconciles adds, edits and deletes on both sides when the peer writes inside the window" do
    with_rule_home do
      write_rewriter(4, [rw_entry(1, "A"), rw_entry(2, "B"), rw_entry(3, "C")])
      Gori::Settings.load

      loaded = Gori::Settings.rewriter_rules
      Gori::Settings.rewriter_rules = [
        loaded[0].copy_with(pattern: "A-ours"), # we edited 1
        loaded[2],                              # 3 untouched; 2 deleted by us
        rw_rule(4_i64, "D-ours"),               # and we added 4
      ]
      Gori::Settings.rewriter_next_rule_id = 5_i64

      # The peer edits 3, adds 5 and advances the counter past ours.
      write_rewriter(6, [rw_entry(1, "A"), rw_entry(2, "B"),
                         rw_entry(3, "C-theirs"), rw_entry(5, "E-theirs")])

      Gori::Settings.save.should be_true

      disk_rewriter_ids.should eq([1_i64, 3_i64, 5_i64, 4_i64])
      # 1 = our edit, 3 = their edit to a rule we left alone, 5 = their add, 4 = our add.
      disk_rewriter_patterns.should eq(["A-ours", "C-theirs", "E-theirs", "D-ours"])
      # The counter is a high-water mark, so neither side "wins" it — the larger stands.
      disk_section("rewriter")["next_rule_id"].as_i64.should eq(6_i64)
    end
  end

  # Ours is the larger one here, so the max is not just "take disk's".
  it "keeps the higher counter when this process is the one ahead" do
    with_rule_home do
      write_rewriter(4, [rw_entry(1, "A")])
      Gori::Settings.load
      Gori::Settings.rewriter_rules = Gori::Settings.rewriter_rules + [rw_rule(9_i64, "ours")]
      Gori::Settings.rewriter_next_rule_id = 10_i64

      write_rewriter(5, [rw_entry(1, "A"), rw_entry(4, "theirs")])
      Gori::Settings.save.should be_true

      disk_section("rewriter")["next_rule_id"].as_i64.should eq(10_i64)
      disk_rewriter_ids.should eq([1_i64, 4_i64, 9_i64])
    end
  end

  # Order is meaning in this list — it is the apply order — so it is merged too, and the two
  # directions are separate decisions.
  it "keeps OUR apply order when we are the ones who reordered" do
    with_rule_home do
      write_rewriter(4, [rw_entry(1, "A"), rw_entry(2, "B"), rw_entry(3, "C")])
      Gori::Settings.load
      loaded = Gori::Settings.rewriter_rules
      Gori::Settings.rewriter_rules = [loaded[1], loaded[0], loaded[2]] # a swap, nothing else

      write_rewriter(5, [rw_entry(1, "A"), rw_entry(2, "B"), rw_entry(3, "C"), rw_entry(4, "D")])
      Gori::Settings.save.should be_true

      # Our order leads and the peer's add follows it — an add always appends, so there is no
      # position of theirs to preserve.
      disk_rewriter_ids.should eq([2_i64, 1_i64, 3_i64, 4_i64])
    end
  end

  it "keeps the PEER's apply order when we only edited a rule" do
    with_rule_home do
      write_rewriter(4, [rw_entry(1, "A"), rw_entry(2, "B"), rw_entry(3, "C")])
      Gori::Settings.load
      loaded = Gori::Settings.rewriter_rules
      Gori::Settings.rewriter_rules = [loaded[0], loaded[1].copy_with(pattern: "B-ours"), loaded[2]]

      write_rewriter(4, [rw_entry(3, "C"), rw_entry(2, "B"), rw_entry(1, "A")]) # they reordered
      Gori::Settings.save.should be_true

      disk_rewriter_ids.should eq([3_i64, 2_i64, 1_i64])
      disk_rewriter_patterns.should eq(["C", "B-ours", "A"]) # their order, our edit
    end
  end

  # A CRUD names a rule by an id read off a list that may already be gone. Answering true there
  # would resurrect a rule the operator deleted in the other window — through the merge's own
  # "I edited it, so mine wins" rule.
  it "answers false rather than resurrecting a rule the peer deleted" do
    with_rule_home do
      write_rewriter(3, [rw_entry(1, "A"), rw_entry(2, "B")])
      Gori::Settings.load

      write_rewriter(3, [rw_entry(1, "A")]) # the peer deletes 2

      Gori::Settings.update_rewriter_rule(2_i64, "request", "head", "B-edited", "v",
        "set_header", "literal", "", "", "").should be_false
      Gori::Settings.set_rewriter_rule_enabled(2_i64, false).should be_false
      Gori::Settings.delete_rewriter_rule(2_i64).should be_false
      Gori::Settings.rewriter_rules.map(&.id).should eq([1_i64])
    end
  end

  # `move` is the one mutation whose re-read the order examples above cannot reach — they stage
  # memory and call `save`, so they never enter `move_rewriter_rule`. A swap is a statement about
  # a POSITION, and a position only means anything against the order the file actually holds:
  # without the re-read, id 3 is still last in the stale copy and the move is refused outright.
  it "swaps inside the order the file holds, not the one this process loaded" do
    with_rule_home do
      write_rewriter(4, [rw_entry(1, "A"), rw_entry(2, "B"), rw_entry(3, "C")])
      Gori::Settings.load

      write_rewriter(4, [rw_entry(3, "C"), rw_entry(2, "B"), rw_entry(1, "A")]) # they reordered

      Gori::Settings.move_rewriter_rule(3_i64, 1).should be_true # it is FIRST now, not last
      disk_rewriter_ids.should eq([2_i64, 3_i64, 1_i64])
    end
  end

  # The keyed merge is only sound while our in-memory id for a rule IS the id in the file, and
  # `claim_id` renumbers an entry whose id is missing, non-positive, at the Int64 ceiling or
  # already taken. For such a file "in the base, absent from disk" is not the peer's delete — it
  # is the same rule under another number — so the merge steps back to the section-level rule,
  # which is exactly what shipped before it existed. What must not happen is a silent drop.
  it "falls back to the section rule when the file's ids are not the ids in memory" do
    with_rule_home do
      File.write(Gori::Settings.path,
        %({"rewriter":{"next_rule_id":3,"rules":[#{rw_entry(1, "A")},#{rw_entry(1, "B")}]}}))
      Gori::Settings.load
      Gori::Settings.rewriter_rules.map(&.id).should eq([1_i64, 2_i64]) # the dupe was renumbered

      id = Gori::Settings.add_rewriter_rule("request", "head", "C", "v",
        "set_header", "literal", "", "", "")
      id.should eq(3_i64)
      disk_rewriter_ids.should eq([1_i64, 2_i64, 3_i64])
      disk_rewriter_patterns.should eq(["A", "B", "C"])
    end
  end
end

describe "Settings — the global colormarker section against a concurrent writer" do
  it "does not mint an id a peer minted while this process held its snapshot" do
    with_rule_home do
      write_colormarker(2, [cm_entry(1, "status:>=500", "red")])
      Gori::Settings.load
      Gori::Settings.colormarker_next_rule_id.should eq(2_i64)

      write_colormarker(3, [cm_entry(1, "status:>=500", "red"), cm_entry(2, "host:cdn", "blue")])

      Gori::Settings.add_colormarker_rule("method:DELETE", "orange", "full").should eq(3_i64)
      disk_colormarker_ids.should eq([1_i64, 2_i64, 3_i64])
    end
  end

  # `colors` and `rules` share the `colormarker` key, so adding a COLOUR used to rewrite the
  # whole section — and delete every rule a peer had added since this process loaded. This is the
  # one the requirement names, and it is why `colors` is keyed by NAME in the same merge.
  it "does not delete a peer's rule when this process adds a custom colour" do
    with_rule_home do
      write_colormarker(2, [cm_entry(1, "status:>=500", "red")])
      Gori::Settings.load

      write_colormarker(3, [cm_entry(1, "status:>=500", "red"), cm_entry(2, "host:cdn", "blue")])

      Gori::Settings.add_colormarker_color("Teal", "008080").should be_nil

      disk_colormarker_ids.should eq([1_i64, 2_i64])
      disk_colormarker_color_names.should eq(["teal"])
      disk_section("colormarker")["next_rule_id"].as_i64.should eq(3_i64)
    end
  end

  # The colour list gets the same four dispositions as the rule list, keyed on the name. The
  # `colors` key is OMITTED from the file when the list is empty, which is why an absent key has
  # to read as "no colours" and not as "unmergeable": read the other way, deleting our last
  # colour would take the peer's new one with it.
  it "reconciles a colour we deleted with one the peer added inside the window" do
    with_rule_home do
      write_colormarker(2, [cm_entry(1, "status:>=500", "red")],
        [cm_color("coral", "#ff6b6b"), cm_color("teal", "#008080")])
      Gori::Settings.load
      Gori::Settings.colormarker_colors.map(&.name).should eq(["coral", "teal"])

      # We drop coral…
      Gori::Settings.colormarker_colors = Gori::Settings.colormarker_colors.reject { |c| c.name == "coral" }
      # …while the peer adds mint.
      write_colormarker(2, [cm_entry(1, "status:>=500", "red")],
        [cm_color("coral", "#ff6b6b"), cm_color("teal", "#008080"), cm_color("mint", "#3eb489")])

      Gori::Settings.save.should be_true
      disk_colormarker_color_names.should eq(["teal", "mint"])
    end
  end

  it "answers false rather than resurrecting a rule the peer deleted" do
    with_rule_home do
      write_colormarker(3, [cm_entry(1, "status:>=500", "red"), cm_entry(2, "host:cdn", "blue")])
      Gori::Settings.load

      write_colormarker(3, [cm_entry(1, "status:>=500", "red")]) # the peer deletes 2

      Gori::Settings.update_colormarker_rule(2_i64, "host:other", "blue", "full").should be_false
      Gori::Settings.set_colormarker_rule_enabled(2_i64, false).should be_false
      Gori::Settings.delete_colormarker_rule(2_i64).should be_false
      Gori::Settings.colormarker_rules.map(&.id).should eq([1_i64])
    end
  end

  # Precedence here is first-match-wins, so a swap made against a stale order does not just look
  # wrong in a list — a different rule paints the row than the operator was just told.
  it "swaps inside the order the file holds, not the one this process loaded" do
    with_rule_home do
      write_colormarker(4, [cm_entry(1, "host:a", "red"), cm_entry(2, "host:b", "blue"),
                            cm_entry(3, "host:c", "green")])
      Gori::Settings.load

      write_colormarker(4, [cm_entry(3, "host:c", "green"), cm_entry(2, "host:b", "blue"),
                            cm_entry(1, "host:a", "red")])

      Gori::Settings.move_colormarker_rule(3_i64, 1).should be_true
      disk_colormarker_ids.should eq([2_i64, 3_i64, 1_i64])
    end
  end

  # A custom colour's NAME is its identity, so the three refusals `add`/`update` make are only as
  # honest as the list they check against — and that list is the one on disk. Answering "added"
  # for a name a peer has already defined is how one of the two hexes silently wins.
  it "refuses a colour name the peer has already taken" do
    with_rule_home do
      write_colormarker(2, [cm_entry(1, "status:>=500", "red")], [cm_color("coral", "#ff6b6b")])
      Gori::Settings.load

      write_colormarker(2, [cm_entry(1, "status:>=500", "red")],
        [cm_color("coral", "#ff6b6b"), cm_color("mint", "#3eb489")])

      Gori::Settings.add_colormarker_color("Mint", "#000000").should_not be_nil
      Gori::Settings.colormarker_color_map["mint"].should eq("#3eb489") # theirs, untouched
    end
  end

  it "refuses to edit or delete a colour the peer has renamed away" do
    with_rule_home do
      write_colormarker(2, [cm_entry(1, "status:>=500", "red")], [cm_color("coral", "#ff6b6b")])
      Gori::Settings.load

      write_colormarker(2, [cm_entry(1, "status:>=500", "red")], [cm_color("salmon", "#ff6b6b")])

      Gori::Settings.update_colormarker_color("coral", "coral", "#111111").should_not be_nil
      Gori::Settings.delete_colormarker_color("coral").should be_false
      Gori::Settings.colormarker_color_map.should eq({"salmon" => "#ff6b6b"})
    end
  end

  # And the last colour going does not take the section's rules with it.
  it "keeps the peer's rule when this process deletes its last custom colour" do
    with_rule_home do
      write_colormarker(2, [cm_entry(1, "status:>=500", "red")], [cm_color("teal", "#008080")])
      Gori::Settings.load

      write_colormarker(3, [cm_entry(1, "status:>=500", "red"), cm_entry(2, "host:cdn", "blue")],
        [cm_color("teal", "#008080")])

      Gori::Settings.delete_colormarker_color("teal").should be_true

      disk_colormarker_ids.should eq([1_i64, 2_i64])
      disk_section("colormarker").as_h.has_key?("colors").should be_false
    end
  end
end
