require "json"

# PET section: Miss Ring, the mascot in the bottom-right of the tab body. See
# settings.cr for the module-level overview and the load/save/serialize orchestration,
# and tui/pet.cr for what these actually drive.
module Gori::Settings
  # OFF by default, unlike every other display pref. She covers three rows of the body's
  # bottom-right corner and — unique among gori's chrome — costs periodic repaints while
  # someone is at the keyboard (~1/s on "lively", ~0.3/s on "calm"; zero once she dozes
  # off after 90s of inactivity). That is an explicit opt-in, never a surprise.
  DEFAULT_PET = false
  # "lively" = blinks, winks, a glint sweep and the occasional wave. "calm" halves the
  # blink rate and drops the rest — for SSH sessions and battery.
  DEFAULT_PET_MOTION  = "lively" # "lively" | "calm"
  DEFAULT_PET_NOTICES = true
  # Where she sits. "body" is the 8x3 sprite in the tab body's bottom-right corner; "bar"
  # is a 7-cell one-row chip in the status row, alongside CPU/MEM and the clock — her
  # middle row alone, so the face survives and only the crown and floor are dropped. The
  # bar form occludes nothing and needs no speech bubble: the status row already carries
  # the toast for exactly these notifications.
  DEFAULT_PET_PLACEMENT = "body" # "body" | "bar"
  # Which glyph repertoire her face is drawn from. Both are the same character wearing the
  # same expressions; they differ in exactly one cell, the resting mouth, and a spec pins
  # that they differ in nothing else.
  #
  # "safe" spells it u — in every monospace cmap, so it renders identically everywhere.
  # "soft" spells it ᴗ (U+1D17), a rounder cup that most monospace fonts lack. That is
  # harmless on a desktop, where the terminal serves it from a fallback face at the same
  # one-column advance, but a stripped container with no fallback pool has nowhere to
  # serve it from and draws a box.
  #
  # Default is "safe": it is the one that cannot fail, and it is the face the look was
  # signed off on. "soft" is there for anyone who prefers the rounder mouth and knows
  # their terminal will find it.
  DEFAULT_PET_FACE = "safe" # "safe" | "soft"

  # All read live at the tick/draw sites, so a save takes effect on the next frame.
  class_property? pet : Bool = DEFAULT_PET
  class_property pet_motion : String = DEFAULT_PET_MOTION
  class_property? pet_notices : Bool = DEFAULT_PET_NOTICES
  class_property pet_placement : String = DEFAULT_PET_PLACEMENT
  class_property pet_face : String = DEFAULT_PET_FACE

  PET_MOTIONS    = {"lively", "calm"}
  PET_PLACEMENTS = {"body", "bar"}
  PET_FACES      = {"safe", "soft"}

  def self.pet_lively? : Bool
    pet_motion != "calm"
  end

  def self.pet_in_bar? : Bool
    pet_placement == "bar"
  end

  # The symbol Mascot draws with. Anything unrecognised has already been normalised on the
  # way in, so this only has to name the one non-default case.
  def self.pet_face_sym : Symbol
    pet_face == "soft" ? :soft : :safe
  end

  # Allowed motion modes; anything else falls back to the default.
  def self.normalize_pet_motion(s : String) : String
    PET_MOTIONS.includes?(s) ? s : DEFAULT_PET_MOTION
  end

  def self.normalize_pet_placement(s : String) : String
    PET_PLACEMENTS.includes?(s) ? s : DEFAULT_PET_PLACEMENT
  end

  def self.normalize_pet_face(s : String) : String
    PET_FACES.includes?(s) ? s : DEFAULT_PET_FACE
  end

  # Tolerant pet section: absent/non-object keeps current.
  private def self.parse_pet(node : JSON::Any?) : Nil
    return unless o = node.try(&.as_h?)
    # load_bool_h, not `|| pet?` — a plain `||` resurrects a stored `false`.
    self.pet = load_bool_h(o, "enabled", pet?)
    self.pet_notices = load_bool_h(o, "notices", pet_notices?)
    o["motion"]?.try(&.as_s?).try { |v| self.pet_motion = normalize_pet_motion(v) }
    o["placement"]?.try(&.as_s?).try { |v| self.pet_placement = normalize_pet_placement(v) }
    o["face"]?.try(&.as_s?).try { |v| self.pet_face = normalize_pet_face(v) }
  end

  # Omitted entirely while every field is at its factory default, so a default install's
  # settings.json stays quiet and the 3-way merge has nothing to reconcile.
  private def self.serialize_pet(j : JSON::Builder) : Nil
    unless pet? == DEFAULT_PET &&
           pet_motion == DEFAULT_PET_MOTION &&
           pet_notices? == DEFAULT_PET_NOTICES &&
           pet_placement == DEFAULT_PET_PLACEMENT &&
           pet_face == DEFAULT_PET_FACE
      j.field "pet" do
        j.object do
          j.field "enabled", pet?
          j.field "placement", pet_placement
          j.field "face", pet_face
          j.field "motion", pet_motion
          j.field "notices", pet_notices?
        end
      end
    end
  end
end
