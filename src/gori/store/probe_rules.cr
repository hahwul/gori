require "db"

module Gori
  class Store
    # Per-project Probe MODE, stored in the generic settings table (key "probe_mode").
    def probe_mode : Probe::Mode
      Probe::Mode.from_setting(setting(Probe::MODE_SETTING_KEY))
    end

    def set_probe_mode(mode : Probe::Mode) : Nil
      set_setting(Probe::MODE_SETTING_KEY, mode.label)
    end

    # --- Probe rule config (per-project) --------------------------------------------------
    # Built-in rules that the operator turned OFF in the Rules sub-tab, by RuleInfo#id. Stored
    # as a JSON array under one settings key (like probe_mode); the analyzer skips these.
    PROBE_DISABLED_KEY = "probe_disabled_rules"

    def probe_disabled_rules : Set(String)
      out = Set(String).new
      raw = setting(PROBE_DISABLED_KEY)
      if raw && !raw.strip.empty?
        JSON.parse(raw).as_a?.try &.each { |e| e.as_s?.try { |s| out << s unless s.empty? } }
      end
      out
    rescue
      Set(String).new
    end

    def set_probe_disabled_rules(ids : Set(String)) : Nil
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

    def update_probe_custom_rule(id : Int64, title : String, description : String, side : String,
                                 region : String, kind : String, pattern : String, severity : Severity) : Nil
      exec_task ->(c : DB::Connection) {
        c.exec("UPDATE probe_custom_rules SET title = ?, description = ?, side = ?, region = ?, kind = ?, pattern = ?, severity = ? WHERE id = ?",
          title, description, side, region, kind, pattern, severity.label, id)
        nil
      }
    end

    def set_probe_custom_rule_enabled(id : Int64, enabled : Bool) : Nil
      exec_task ->(c : DB::Connection) { c.exec("UPDATE probe_custom_rules SET enabled = ? WHERE id = ?", enabled ? 1 : 0, id); nil }
    end

    def delete_probe_custom_rule(id : Int64) : Nil
      exec_task ->(c : DB::Connection) { c.exec("DELETE FROM probe_custom_rules WHERE id = ?", id); nil }
    end
  end
end
