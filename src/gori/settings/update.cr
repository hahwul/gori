require "json"

# Startup update-check settings — the state behind the ProjectPicker's one-line
# "update available" notice. See settings.cr for the load/save orchestration.
#
# The picker does a best-effort background probe of the latest GitHub release and,
# when it's newer than the running binary, shows a brief hint above the key row —
# once per new release (the read-once marker). This is the ONLY automatic outbound
# call gori makes; `gori update` stays the explicit install path.
module Gori::Settings
  # check_enabled: opt-out for egress-sensitive users (default on — the maintainer
  #   asked for the notice). Gating it off skips the probe entirely.
  # notified_version: the latest version we've already surfaced — the read-once marker.
  # latest_seen / checked_at: a once-a-day cache (unix seconds) so we don't re-probe
  #   GitHub on every launch; only refreshed on a successful live fetch.
  DEFAULT_UPDATE_CHECK_ENABLED = true

  class_property? update_check_enabled : Bool = DEFAULT_UPDATE_CHECK_ENABLED
  class_property update_notified_version : String = ""
  class_property update_latest_seen : String = ""
  class_property update_checked_at : Int64 = 0_i64

  # Tolerant update section: absent/non-object keeps current.
  private def self.parse_update(node : JSON::Any?) : Nil
    return unless o = node.try(&.as_h?)
    self.update_check_enabled = load_bool_h(o, "check_enabled", update_check_enabled?)
    if v = o["notified_version"]?.try(&.as_s?)
      self.update_notified_version = v
    end
    if v = o["latest_seen"]?.try(&.as_s?)
      self.update_latest_seen = v
    end
    if v = o["checked_at"]?.try(&.as_i64?)
      self.update_checked_at = v
    end
  end

  # Factory reset for this section (dispatched by Settings.reset_to_factory). The three
  # bookkeeping fields go with the toggle: they are this install's memory of what it has
  # already checked and told the operator about, which a factory reset is meant to forget.
  defaulted_section update, "update",
    {"check_enabled", update_check_enabled?, DEFAULT_UPDATE_CHECK_ENABLED},
    {"notified_version", update_notified_version, ""},
    {"latest_seen", update_latest_seen, ""},
    {"checked_at", update_checked_at, 0_i64}
end
