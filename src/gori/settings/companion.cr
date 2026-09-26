require "json"

# COMPANION section: Miss Ring, the mascot in the bottom-right of the tab body. See
# settings.cr for the module-level overview and the load/save/serialize orchestration,
# and tui/companion.cr for what these actually drive.
module Gori::Settings
  # ON by default: she is part of what gori looks like, not an extra someone has to find.
  # She covers three rows of the body's bottom-right corner and — unique among gori's
  # chrome — costs periodic repaints while someone is at the keyboard (~1/s on "lively",
  # ~0.3/s on "calm"; zero once she dozes off after 90s of inactivity). Everyone who does
  # not want that says so ONCE: turning her off no longer matches the factory default, so
  # serialize_companion writes `"enabled": false` and the answer survives every upgrade.
  # (Under the old default the same answer was written by omitting the section, which is
  # why this flip reaches an install that declined her in the wizard.) The two costs have
  # a setting each short of turning her off: motion "still" drops every repaint she starts
  # herself, and placement "bar" gives the three body rows back.
  DEFAULT_COMPANION = true
  # "lively" = blinks, winks, a glint sweep, and about every 25 seconds one of seven idle
  # gestures (a yawn, a smile, a squint, a deadpan, a curious look, a huff, an "hmm").
  # "calm" halves the blink rate and drops the rest — for SSH sessions and battery.
  # "still" drops the blink too, so nothing she does on her own moves at all: #compose
  # then returns the same frame on every beat and #tick reports a change exactly never
  # while she is idle. That is for an asciinema recording, a screen reader, a shared tmux
  # pane and anywhere a repainting corner is noise rather than company — and it is a
  # THIRD mode rather than a second meaning for "calm", because someone who picked calm
  # asked for a quieter mascot, not for a still image.
  #
  # Her REACTIONS to results are not motion she starts on her own, so all three modes play
  # them, arc and all (tui/companion.cr#pose_for). "still" is the one exception, and only
  # for the part of a reaction that is literally movement: the :error shudder displaces
  # her a column, so it is suppressed while the face change it accompanies is not.
  DEFAULT_COMPANION_MOTION  = "lively" # "lively" | "calm" | "still"
  DEFAULT_COMPANION_NOTICES = true
  # Where she sits. "body" is the 8x3 sprite in the tab body's bottom-right corner; "bar"
  # is an 8-cell one-row chip in the status row, alongside CPU/MEM and the clock — her
  # middle row plus the mood badge, so the face and the one glyph that says "something is
  # wrong" both survive, and only the crown and floor are dropped. The bar form occludes
  # nothing and needs no speech bubble: the status row already carries the toast for
  # exactly these notifications.
  DEFAULT_COMPANION_PLACEMENT = "body" # "body" | "bar"
  # How long she keeps saying an agent's reply (`reply_to_operator`). "hold" keeps it in the
  # bubble — or the status row, in `bar` — until the operator's next key or click; "timed"
  # lets it go after the few seconds every other notice gets. HOLD BY DEFAULT because a reply
  # is the one notice written TO the operator, and the only live copy of it: an agent that
  # answered while they were reading a response in another pane was, on a 3.5s bubble,
  # an agent that had not answered at all. A later job result does not take a held bubble;
  # a later reply does.
  DEFAULT_COMPANION_REPLIES = "hold" # "hold" | "timed"

  # All read live at the tick/draw sites, so a save takes effect on the next frame.
  class_property? companion : Bool = DEFAULT_COMPANION
  class_property companion_motion : String = DEFAULT_COMPANION_MOTION
  class_property? companion_notices : Bool = DEFAULT_COMPANION_NOTICES
  class_property companion_placement : String = DEFAULT_COMPANION_PLACEMENT
  class_property companion_replies : String = DEFAULT_COMPANION_REPLIES

  COMPANION_MOTIONS    = {"lively", "calm", "still"}
  COMPANION_PLACEMENTS = {"body", "bar"}
  COMPANION_REPLIES    = {"hold", "timed"}

  # NAMED POSITIVELY, not as "not calm". This read `!= "calm"` while there were two modes,
  # which is the same answer written the way that does not survive a third: "still" would
  # have arrived as the liveliest mode there is, winks and glint and all.
  def self.companion_lively? : Bool
    companion_motion == "lively"
  end

  # Nothing she starts herself moves. See DEFAULT_COMPANION_MOTION for what that excludes.
  def self.companion_still? : Bool
    companion_motion == "still"
  end

  def self.companion_in_bar? : Bool
    companion_placement == "bar"
  end

  def self.companion_holds_replies? : Bool
    companion_replies == "hold"
  end

  # Allowed motion modes; anything else falls back to the default.
  def self.normalize_companion_motion(s : String) : String
    COMPANION_MOTIONS.includes?(s) ? s : DEFAULT_COMPANION_MOTION
  end

  def self.normalize_companion_placement(s : String) : String
    COMPANION_PLACEMENTS.includes?(s) ? s : DEFAULT_COMPANION_PLACEMENT
  end

  def self.normalize_companion_replies(s : String) : String
    COMPANION_REPLIES.includes?(s) ? s : DEFAULT_COMPANION_REPLIES
  end

  # Tolerant companion section: absent/non-object keeps current.
  private def self.parse_companion(node : JSON::Any?) : Nil
    return unless o = node.try(&.as_h?)
    # load_bool_h, not `|| companion?` — a plain `||` resurrects a stored `false`.
    self.companion = load_bool_h(o, "enabled", companion?)
    self.companion_notices = load_bool_h(o, "notices", companion_notices?)
    o["motion"]?.try(&.as_s?).try { |v| self.companion_motion = normalize_companion_motion(v) }
    o["placement"]?.try(&.as_s?).try { |v| self.companion_placement = normalize_companion_placement(v) }
    o["replies"]?.try(&.as_s?).try { |v| self.companion_replies = normalize_companion_replies(v) }
  end

  # Factory reset for this section (dispatched by Settings.reset_to_factory). One assignment
  # per field serialize_companion writes. The source-grep guard only checks that this method
  # EXISTS and is dispatched (see display.cr's block) — keeping the two field lists in step is
  # a hand job, so add to both in the same edit.
  private def self.reset_companion : Nil
    self.companion = DEFAULT_COMPANION
    self.companion_placement = DEFAULT_COMPANION_PLACEMENT
    self.companion_motion = DEFAULT_COMPANION_MOTION
    self.companion_notices = DEFAULT_COMPANION_NOTICES
    self.companion_replies = DEFAULT_COMPANION_REPLIES
  end

  # Omitted entirely while every field is at its factory default, so a default install's
  # settings.json stays quiet and the 3-way merge has nothing to reconcile.
  private def self.serialize_companion(j : JSON::Builder) : Nil
    unless companion? == DEFAULT_COMPANION &&
           companion_motion == DEFAULT_COMPANION_MOTION &&
           companion_notices? == DEFAULT_COMPANION_NOTICES &&
           companion_placement == DEFAULT_COMPANION_PLACEMENT &&
           companion_replies == DEFAULT_COMPANION_REPLIES
      j.field "companion" do
        j.object do
          j.field "enabled", companion?
          j.field "placement", companion_placement
          j.field "motion", companion_motion
          j.field "notices", companion_notices?
          j.field "replies", companion_replies
        end
      end
    end
  end
end
