require "json"

# COMPANION section: Miss Ring, the mascot in the bottom-right of the tab body. See
# settings.cr for the module-level overview and the load/save/serialize orchestration,
# and tui/companion.cr for what these actually drive.
module Gori::Settings
  # OFF by default, unlike every other display pref. She covers three rows of the body's
  # bottom-right corner and — unique among gori's chrome — costs periodic repaints while
  # someone is at the keyboard (~1/s on "lively", ~0.3/s on "calm"; zero once she dozes
  # off after 90s of inactivity). That is an explicit opt-in, never a surprise.
  DEFAULT_COMPANION = false
  # "lively" = blinks, winks, a glint sweep, and about every 25 seconds one of seven idle
  # gestures (a yawn, a smile, a squint, a deadpan, a curious look, a huff, an "hmm").
  # "calm" halves the blink rate and drops the rest — for SSH sessions and battery. Her
  # REACTIONS to results are not motion she starts on her own, so both modes play them,
  # arc and all (tui/companion.cr#pose_for).
  DEFAULT_COMPANION_MOTION  = "lively" # "lively" | "calm"
  DEFAULT_COMPANION_NOTICES = true
  # Where she sits. "body" is the 8x3 sprite in the tab body's bottom-right corner; "bar"
  # is a 7-cell one-row chip in the status row, alongside CPU/MEM and the clock — her
  # middle row alone, so the face survives and only the crown and floor are dropped. The
  # bar form occludes nothing and needs no speech bubble: the status row already carries
  # the toast for exactly these notifications.
  DEFAULT_COMPANION_PLACEMENT = "body" # "body" | "bar"

  # All read live at the tick/draw sites, so a save takes effect on the next frame.
  class_property? companion : Bool = DEFAULT_COMPANION
  class_property companion_motion : String = DEFAULT_COMPANION_MOTION
  class_property? companion_notices : Bool = DEFAULT_COMPANION_NOTICES
  class_property companion_placement : String = DEFAULT_COMPANION_PLACEMENT

  COMPANION_MOTIONS    = {"lively", "calm"}
  COMPANION_PLACEMENTS = {"body", "bar"}

  def self.companion_lively? : Bool
    companion_motion != "calm"
  end

  def self.companion_in_bar? : Bool
    companion_placement == "bar"
  end

  # Allowed motion modes; anything else falls back to the default.
  def self.normalize_companion_motion(s : String) : String
    COMPANION_MOTIONS.includes?(s) ? s : DEFAULT_COMPANION_MOTION
  end

  def self.normalize_companion_placement(s : String) : String
    COMPANION_PLACEMENTS.includes?(s) ? s : DEFAULT_COMPANION_PLACEMENT
  end

  # Tolerant companion section: absent/non-object keeps current.
  private def self.parse_companion(node : JSON::Any?) : Nil
    return unless o = node.try(&.as_h?)
    # load_bool_h, not `|| companion?` — a plain `||` resurrects a stored `false`.
    self.companion = load_bool_h(o, "enabled", companion?)
    self.companion_notices = load_bool_h(o, "notices", companion_notices?)
    o["motion"]?.try(&.as_s?).try { |v| self.companion_motion = normalize_companion_motion(v) }
    o["placement"]?.try(&.as_s?).try { |v| self.companion_placement = normalize_companion_placement(v) }
  end

  # Omitted entirely while every field is at its factory default, so a default install's
  # settings.json stays quiet and the 3-way merge has nothing to reconcile.
  private def self.serialize_companion(j : JSON::Builder) : Nil
    unless companion? == DEFAULT_COMPANION &&
           companion_motion == DEFAULT_COMPANION_MOTION &&
           companion_notices? == DEFAULT_COMPANION_NOTICES &&
           companion_placement == DEFAULT_COMPANION_PLACEMENT
      j.field "companion" do
        j.object do
          j.field "enabled", companion?
          j.field "placement", companion_placement
          j.field "motion", companion_motion
          j.field "notices", companion_notices?
        end
      end
    end
  end
end
