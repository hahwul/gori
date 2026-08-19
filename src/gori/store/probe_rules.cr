require "db"

module Gori
  class Store
    # Per-project Probe MODE, stored in the generic settings table (key "probe_mode").
    def probe_mode : Probe::Mode
      Probe::Mode.from_setting(setting(Probe::MODE_SETTING_KEY))
    end

    # Returns whether the write COMMITTED (false = store busy/locked/closing), for the same
    # reason `set_probe_disabled_rules` below does — `set_setting` is `exec_task_ok`, so the
    # answer was already here and only had to stop being thrown away. The direction that
    # matters is setting `off`/`passive` to STOP active probing: every surface reported that
    # as done, while a separate live instance kept the persisted `active`/`aggressive` mode
    # and kept firing attack payloads at production.
    def set_probe_mode(mode : Probe::Mode) : Bool
      set_setting(Probe::MODE_SETTING_KEY, mode.label)
    end

    # --- Probe rule config (per-project) --------------------------------------------------
    # Built-in rules that the operator turned OFF in the Rules sub-tab, by RuleInfo#id. Stored
    # as a JSON array under one settings key (like probe_mode); the analyzer skips these.
    PROBE_DISABLED_KEY = "probe_disabled_rules"

    # The built-in probe rules the operator turned OFF, tolerant form: an unreadable/corrupt
    # value degrades to the empty set. This is the DISPLAY/edit read — the Rules sub-tab, the
    # rule list, and the toggle commands — where an unreadable value should render as
    # "nothing disabled" rather than crash the surface (the TUI event loop has no catch-all).
    def probe_disabled_rules : Set(String)
      probe_disabled_rules_strict
    rescue
      Set(String).new
    end

    # The AUTHORIZATION read for active probing. This set is the ONLY thing between an ACTIVE
    # rule the operator disabled and a real request, so here a read failure must NOT look like
    # "nothing is disabled": it RAISES, and the callers in `Scan`/`Analyzer` rescue it and fail
    # CLOSED (skip active probing rather than send everything). A malformed-but-readable value
    # is still tolerated per element — a single bad entry should not blind the whole set.
    def probe_disabled_rules_strict : Set(String)
      out = Set(String).new
      raw = setting(PROBE_DISABLED_KEY)
      if raw && !raw.strip.empty?
        # A truncated/corrupt JSON blob RAISES here (JSON::ParseException) — deliberately not
        # rescued, so the failure reaches the fail-closed active-send callers.
        JSON.parse(raw).as_a?.try &.each { |e| e.as_s?.try { |s| out << s unless s.empty? } }
      end
      out
    end

    # Returns whether the write COMMITTED (false = store busy/locked/closing). Both branches
    # already had the answer — `set_setting`/`delete_setting` are `exec_task_ok` — and this
    # threw it away, so every caller that toggles a scan rule had to claim success blind.
    def set_probe_disabled_rules(ids : Set(String)) : Bool
      if ids.empty?
        delete_setting(PROBE_DISABLED_KEY)
      else
        set_setting(PROBE_DISABLED_KEY, ids.to_a.to_json)
      end
    end

    # Per-project user-defined custom match rules (project scope). Global-scope rules live in
    # settings.json; Probe.custom_rules merges both. CRUD mirrors match_rules.
    def probe_custom_rules : Array(ProbeCustomRule)
      list = [] of ProbeCustomRule
      @db.query("SELECT id, title, description, side, region, kind, pattern, severity, enabled FROM probe_custom_rules ORDER BY id") do |rs|
        rs.each do
          list << ProbeCustomRule.new(
            rs.read(Int64), rs.read(String), rs.read(String), rs.read(String),
            rs.read(String), rs.read(String), rs.read(String),
            Severity.parse?(rs.read(String)) || Severity::Info, rs.read(Int32) != 0)
        end
      end
      list
    rescue
      [] of ProbeCustomRule
    end

    def insert_probe_custom_rule(title : String, description : String, side : String, region : String,
                                 kind : String, pattern : String, severity : Severity, enabled : Bool = true) : Int64
      exec_task ->(c : DB::Connection) {
        c.exec("INSERT INTO probe_custom_rules (title, description, side, region, kind, pattern, severity, enabled) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
          title, description, side, region, kind, pattern, severity.label, enabled ? 1 : 0)
        nil
      }
    end

    # `exec_task_ok`, not `exec_task`: for the same reason `set_probe_custom_rule_enabled` below
    # is — an UPDATE reports nothing through last_insert_rowid, so the commit flag is the only
    # way a caller can tell a persisted edit from a rolled-back one. Here the stake is the rule
    # BODY rather than its enabled bit: an operator told a re-written `pattern` was saved over a
    # batch that rolled back keeps scanning with the OLD pattern, so the finding it was widened
    # to catch is a false negative they have been told not to expect.
    def update_probe_custom_rule(id : Int64, title : String, description : String, side : String,
                                 region : String, kind : String, pattern : String, severity : Severity) : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("UPDATE probe_custom_rules SET title = ?, description = ?, side = ?, region = ?, kind = ?, pattern = ?, severity = ? WHERE id = ?",
          title, description, side, region, kind, pattern, severity.label, id)
        nil
      }
    end

    # `exec_task_ok`, not `exec_task`: an UPDATE reports nothing through last_insert_rowid, so
    # this is the only way a caller can tell a committed toggle from a rolled-back one — and
    # this one mutes or unmutes a security scan rule. Same reason `set_rule_enabled` (Match &
    # Replace) and `update_probe_issue_status` already return Bool.
    def set_probe_custom_rule_enabled(id : Int64, enabled : Bool) : Bool
      exec_task_ok ->(c : DB::Connection) { c.exec("UPDATE probe_custom_rules SET enabled = ? WHERE id = ?", enabled ? 1 : 0, id); nil }
    end

    def delete_probe_custom_rule(id : Int64) : Bool
      exec_task_ok ->(c : DB::Connection) { c.exec("DELETE FROM probe_custom_rules WHERE id = ?", id); nil }
    end
  end
end
