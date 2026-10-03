require "json"

# SCAN RULES section (settings:probe rules → global scope): user-defined Probe
# match rules, reusable across every project. See settings.cr for the module-level
# overview and the load/save/serialize orchestration.
module Gori::Settings
  # A GLOBAL user-defined Probe match rule (settings.json "scan_rules"), reusable across every
  # project. `severity` is the lowercase Store::Severity label ("info".."critical");
  # Probe.custom_rules maps these into the runtime match list. Project-scoped rules live in the
  # project DB (probe_custom_rules). `id` is a random hex token assigned on creation.
  record ScanRule,
    id : String,
    title : String,
    description : String,
    side : String,   # "request" | "response"
    region : String, # "whole" | "header" | "body"
    kind : String,   # "string" | "regex" | "exec" (an argv — see Probe::CustomRule)
    pattern : String,
    severity : String, # lowercase Store::Severity label
    enabled : Bool do
    # Does this rule RUN AN EXTERNAL COMMAND when it fires? The scan-rule half of
    # `Store::RuleOp#executes?` — the same trust boundary, asked of a `kind` instead of an op
    # because a scan rule's kinds are bare labels with no enum behind them. `Probe::CustomRule`
    # is what the kind means at run time (`exec_evidence`); `Settings.command_rules` is what
    # asks it of a profile (#842).
    def executes? : Bool
      ScanRule.executes?(kind)
    end

    # The same question of a kind that has no record yet — a would-be rule is validated before
    # one exists (`Probe::CustomRule.valid_pattern?`), so the predicate cannot live only on the
    # instance.
    def self.executes?(kind : String) : Bool
      kind == SCAN_RULE_EXEC_KIND
    end

    # An exec rule's ARGV, or nil when it does not run one. It lives in `pattern` — the field
    # holds a match spec for every other kind and a command line for this one (see
    # `Probe::CustomRule#exec_evidence`). Mirrors `RewriterRule#command`.
    def command : String?
      executes? ? pattern : nil
    end
  end
  class_property scan_rules : Array(ScanRule) = [] of ScanRule

  SCAN_RULE_SIDES   = %w[request response]
  SCAN_RULE_REGIONS = %w[whole header body]

  # The one kind whose `pattern` is an ARGV rather than a match spec (#818). Spelled once so
  # `SCAN_RULE_KINDS` and `ScanRule.executes?` cannot disagree about it.
  SCAN_RULE_EXEC_KIND = "exec"
  SCAN_RULE_KINDS     = ["string", "regex", SCAN_RULE_EXEC_KIND]

  SCAN_RULE_SEVERITIES = %w[info low medium high critical]

  # Tolerant global-scan-rule parse: a non-array (or absent) node keeps the current value;
  # entries missing id/title/pattern are dropped; side/region/kind/severity are clamped to
  # their allowed sets (default to the safest choice) so a hand-edited file can't smuggle an
  # invalid enum into the match engine. Mirrors parse_hostname_overrides' robustness.
  private def self.parse_scan_rules(node : JSON::Any?) : Array(ScanRule)
    arr = node.try(&.as_a?)
    return scan_rules unless arr
    out = [] of ScanRule
    arr.each do |e|
      next unless o = e.as_h?
      id = o["id"]?.try(&.as_s?)
      title = o["title"]?.try(&.as_s?)
      pattern = o["pattern"]?.try(&.as_s?)
      next if id.nil? || id.empty? || title.nil? || title.empty? || pattern.nil? || pattern.empty?
      side = clamp_field(o["side"]?.try(&.as_s?), SCAN_RULE_SIDES, "response")
      region = clamp_field(o["region"]?.try(&.as_s?), SCAN_RULE_REGIONS, "body")
      kind = clamp_field(o["kind"]?.try(&.as_s?), SCAN_RULE_KINDS, "string")
      severity = clamp_field(o["severity"]?.try(&.as_s?), SCAN_RULE_SEVERITIES, "info")
      desc = o["description"]?.try(&.as_s?) || ""
      enabled = o["enabled"]?.try(&.as_bool?)
      out << ScanRule.new(id, title, desc, side, region, kind, pattern, severity, enabled.nil? ? true : enabled)
    end
    out
  end

  private def self.clamp_field(val : String?, allowed : Array(String), default : String) : String
    v = val.try(&.downcase)
    (v && allowed.includes?(v)) ? v : default
  end

  # --- global scan-rule library CRUD (settings:probe rules → global scope) -----------------
  # Each mutation rewrites the array and persists via save (atomic + 3-way merge). The array
  # ORDER is the list order; add appends.
  #
  # Every one of these returns a COMMIT answer, so each goes through `commit`: a rule left live
  # in `scan_rules` over a refused save is folded straight into the runtime match list by
  # `Probe.custom_rules`, so the operator kept scanning with a pattern that reverts at next
  # start. Same shape as `add_rewriter_rule`, minus the burned-counter restore it needs: ids
  # here are `Random::Secure.hex`, so a refused add has no counter to put back.

  # Every one also opens by re-reading the section, as the rewriter CRUD does, so it edits what
  # a peer gori left on disk rather than a snapshot that still holds the peer's deletions.
  def self.reload_scan_rules_from_disk : Nil
    reload_section("scan_rules", absent: JSON::Any.new([] of JSON::Any), object: false) do |node|
      self.scan_rules = parse_scan_rules(node)
    end
  end

  # Returns the new rule's generated id so the caller can select it, or "" when the write did
  # not reach disk — the `0_i64` of `add_rewriter_rule` in this family's id type.
  def self.add_scan_rule(title : String, description : String, side : String, region : String,
                         kind : String, pattern : String, severity : String, enabled : Bool = true) : String
    reload_scan_rules_from_disk
    id = Random::Secure.hex(4)
    commit(scan_rules, scan_rules + [ScanRule.new(id, title, description, side, region, kind, pattern, severity, enabled)]) ? id : ""
  end

  def self.update_scan_rule(id : String, title : String, description : String, side : String,
                            region : String, kind : String, pattern : String, severity : String) : Bool
    reload_scan_rules_from_disk
    commit(scan_rules, replace_by_id(scan_rules, id) do |r|
      ScanRule.new(id, title, description, side, region, kind, pattern, severity, r.enabled)
    end)
  end

  def self.set_scan_rule_enabled(id : String, enabled : Bool) : Bool
    reload_scan_rules_from_disk
    commit(scan_rules, replace_by_id(scan_rules, id, &.copy_with(enabled: enabled)))
  end

  def self.delete_scan_rule(id : String) : Bool
    reload_scan_rules_from_disk
    # This one fails the OTHER way round: a dropped-then-unsaved rule has stopped matching
    # while the caller reports "not deleted — it is still scanning". An operator removing a
    # noisy rule has to be able to trust that sentence.
    commit(scan_rules, remove_by_id(scan_rules, id))
  end

  # Factory reset for this section (dispatched by Settings.reset_to_factory).
  private def self.reset_scan_rules : Nil
    self.scan_rules = [] of ScanRule
  end

  # Omit when empty so an untouched install never writes "scan_rules": [].
  private def self.serialize_scan_rules(j : JSON::Builder) : Nil
    unless scan_rules.empty?
      j.field "scan_rules" do
        j.array do
          scan_rules.each do |r|
            j.object do
              j.field "id", r.id
              j.field "title", r.title
              j.field "description", r.description
              j.field "side", r.side
              j.field "region", r.region
              j.field "kind", r.kind
              j.field "pattern", r.pattern
              j.field "severity", r.severity
              j.field "enabled", r.enabled
            end
          end
        end
      end
    end
  end
end
