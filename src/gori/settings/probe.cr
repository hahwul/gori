require "json"

# PROBE section: last "Run active scan" notification choice (global scratch — the
# run popup's cycler default). See settings.cr for the module-level overview and
# the load/save/serialize orchestration.
module Gori::Settings
  # Last "Run active scan" notification choice (global scratch — the run popup's cycler
  # default). Mirrors mine_notify's token set ("when-found"/"off"/"always").
  DEFAULT_PROBE_ACTIVE_NOTIFY = "when-found"

  class_property probe_active_notify : String = DEFAULT_PROBE_ACTIVE_NOTIFY

  # Persist the "Run active scan" popup's last notification choice.
  def self.save_probe_active_notify(notify : String) : Nil
    self.probe_active_notify = notify
    save
  end

  # Factory reset for this section (dispatched by Settings.reset_to_factory).
  private def self.reset_probe : Nil
    self.probe_active_notify = DEFAULT_PROBE_ACTIVE_NOTIFY
  end

  private def self.serialize_probe(j : JSON::Builder) : Nil
    j.field "probe" do
      j.object { j.field "active_notify", probe_active_notify }
    end
  end
end
