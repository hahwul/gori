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
    kind : String,   # "string" | "regex"
    pattern : String,
    severity : String, # lowercase Store::Severity label
    enabled : Bool
  class_property scan_rules : Array(ScanRule) = [] of ScanRule

  SCAN_RULE_SIDES      = %w[request response]
  SCAN_RULE_REGIONS    = %w[whole header body]
  SCAN_RULE_KINDS      = %w[string regex]
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
  # Every one of these returns a COMMIT answer, so memory has to agree with it: `save` refuses
  # the write outright when the last load only got half the file in (`@@load_partial`), and it
  # returns false on any transient write failure too. Mutating first and answering false left
  # the rule live in `scan_rules` — folded straight into the runtime match list by
  # `Probe.custom_rules`, so the operator kept scanning with a pattern that reverts at next
  # start — and written to disk by the next unrelated save that did succeed. So snapshot the
  # array and put it back when the write did not commit. The array is replaced wholesale
  # everywhere and never mutated in place, so the old reference IS the snapshot. Same shape as
  # `add_rewriter_rule`, minus the burned-counter restore it needs: ids here are
  # `Random::Secure.hex`, so a refused add has no counter to put back.

  # Returns the new rule's generated id so the caller can select it, or "" when the write did
  # not reach disk — the `0_i64` of `add_rewriter_rule` in this family's id type.
  def self.add_scan_rule(title : String, description : String, side : String, region : String,
                         kind : String, pattern : String, severity : String, enabled : Bool = true) : String
    prev = scan_rules
    id = Random::Secure.hex(4)
    self.scan_rules = scan_rules + [ScanRule.new(id, title, description, side, region, kind, pattern, severity, enabled)]
    return id if save
    self.scan_rules = prev
    ""
  end

  def self.update_scan_rule(id : String, title : String, description : String, side : String,
                            region : String, kind : String, pattern : String, severity : String) : Bool
    prev = scan_rules
    found = false
    self.scan_rules = scan_rules.map do |r|
      next r unless r.id == id
      found = true
      ScanRule.new(id, title, description, side, region, kind, pattern, severity, r.enabled)
    end
    ok = found && save
    self.scan_rules = prev unless ok
    ok
  end

  def self.set_scan_rule_enabled(id : String, enabled : Bool) : Bool
    prev = scan_rules
    found = false
    self.scan_rules = scan_rules.map do |r|
      next r unless r.id == id
      found = true
      r.copy_with(enabled: enabled)
    end
    ok = found && save
    self.scan_rules = prev unless ok
    ok
  end

  def self.delete_scan_rule(id : String) : Bool
    prev = scan_rules
    kept = scan_rules.reject { |r| r.id == id }
    return false if kept.size == scan_rules.size
    self.scan_rules = kept
    # This one fails the OTHER way round: a dropped-then-unsaved rule has stopped matching
    # while the caller reports "not deleted — it is still scanning". An operator removing a
    # noisy rule has to be able to trust that sentence.
    return true if save
    self.scan_rules = prev
    false
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
