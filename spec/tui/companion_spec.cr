require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# Runs `block` with Miss Ring forced on/off (and a motion mode), restoring both.
private def with_companion(enabled : Bool, motion : String = "lively", notices : Bool = true, &)
  prev = {Gori::Settings.companion?, Gori::Settings.companion_motion, Gori::Settings.companion_notices?}
  Gori::Settings.companion = enabled
  Gori::Settings.companion_motion = motion
  Gori::Settings.companion_notices = notices
  begin
    yield
  ensure
    Gori::Settings.companion = prev[0]
    Gori::Settings.companion_motion = prev[1]
    Gori::Settings.companion_notices = prev[2]
  end
end

# Step the companion forward `n` beats from `t0`, returning how many of those ticks reported a
# change. Beats are stepped one at a time because #advance re-bases on `now`, not on
# last + BEAT — a single jump would collapse the whole span into one beat.
private def beats(companion : Companion, t0 : Time::Instant, n : Int32) : Int32
  (1..n).count { |i| companion.tick(t0 + Companion::BEAT * i) }
end

# Step `n` beats and hand every drawn frame to the block. She is kept awake by hand:
# SLEEP_AFTER is 450 beats and a dozing companion stops advancing the beat entirely, so a
# sweep long enough to catch a RARE track has to poke her, exactly as someone at the
# keyboard does. Poking while awake only re-arms the idle clock — it cannot arm the startle.
private def gesture_sweep(n : Int32, motion : String, &block : Mascot::Frame ->) : Nil
  with_companion(true, motion) do
    companion = Companion.new(Notifications.new)
    t0 = Time.instant
    companion.tick(t0)
    n.times do |i|
      now = t0 + Companion::BEAT * (i + 1)
      companion.poke(now)
      companion.tick(now)
      companion.frame.try { |f| block.call(f) }
    end
  end
end

describe Gori::Tui::Companion do
  # The hello is once per PROCESS, not once per Companion (Companion.@@greeted) — so without this
  # every example after the first would inherit "already greeted" from whichever ran
  # before it, and the greeting assertions would pass or fail on spec ordering.
  before_each { Companion.forget_greeting! }

  # --- the tick contract (idle-zero-CPU) ------------------------------------

  it "does nothing while disabled" do
    with_companion(false) do
      companion = Companion.new(Notifications.new)
      companion.tick(Time.instant).should be_false
      companion.frame.should be_nil
    end
  end

  it "produces an idle frame on the first tick" do
    with_companion(true) do
      companion = Companion.new(Notifications.new)
      companion.tick(Time.instant).should be_true
      companion.frame.not_nil!.pose.should eq(:idle)
    end
  end

  it "does not re-compose before a beat elapses" do
    with_companion(true) do
      companion = Companion.new(Notifications.new)
      t0 = Time.instant
      companion.tick(t0).should be_true
      companion.tick(t0 + Companion::BEAT - 1.millisecond).should be_false
    end
  end

  # The repaint budget the feature is sold on: awake and quiet, she must change the drawn
  # frame only a handful of times per minute — NOT once per beat. Asserted as a rate so
  # retuning the schedule constants doesn't require editing a hardcoded count.
  it "changes the drawn frame far less often than it beats" do
    with_companion(true) do
      companion = Companion.new(Notifications.new)
      t0 = Time.instant
      companion.tick(t0)
      n = (Companion::SLEEP_AFTER.total_milliseconds / Companion::BEAT.total_milliseconds).to_i - 1
      changed = beats(companion, t0, n)
      changed.should be > 0                 # she is not frozen
      changed.should be < (n * 3 / 10).to_i # …but well under a third of the beats
    end
  end

  # THE idle-zero-CPU test. After SLEEP_AFTER with no poke she must transition to :doze
  # exactly once and then report nothing, forever.
  it "dozes off and then stops reporting entirely" do
    with_companion(true) do
      companion = Companion.new(Notifications.new)
      t0 = Time.instant
      companion.tick(t0)
      companion.tick(t0 + Companion::SLEEP_AFTER).should be_true
      companion.frame.not_nil!.pose.should eq(:doze)
      companion.frame.not_nil!.badge.should eq('z') # reads as asleep, not as a hang
      companion.tick(t0 + Companion::SLEEP_AFTER + Companion::BEAT).should be_false
      companion.tick(t0 + 1.hour).should be_false
    end
  end

  it "wakes from a doze on input and settles back to idle" do
    with_companion(true) do
      companion = Companion.new(Notifications.new)
      t0 = Time.instant
      companion.tick(t0)
      companion.tick(t0 + Companion::SLEEP_AFTER)
      woke = t0 + Companion::SLEEP_AFTER + 1.second
      companion.poke(woke)
      companion.tick(woke + Companion::BEAT).should be_true
      companion.frame.not_nil!.pose.should eq(:alert) # startled
      beats(companion, woke, Companion::WAKE_BEATS + 2)
      companion.frame.not_nil!.pose.should_not eq(:doze)
    end
  end

  it "drops the frame once on the disable edge, then stays quiet" do
    companion = Companion.new(Notifications.new)
    with_companion(true) { companion.tick(Time.instant).should be_true }
    with_companion(false) do
      companion.tick(Time.instant).should be_true
      companion.frame.should be_nil
      companion.tick(Time.instant).should be_false
    end
  end

  # The watermark has to stay current while she is OFF, or enabling her mid-session
  # replays whatever landed in the meantime as if it just happened.
  it "does not announce a backlog accumulated while she was off" do
    notes = Notifications.new
    companion = Companion.new(notes)
    t0 = Time.instant
    with_companion(false) { companion.tick(t0) }
    notes.push(:error, "probe: boom") # arrives while she is hidden
    with_companion(true) do
      companion.tick(t0 + Companion::BEAT)
      f = companion.frame.not_nil!
      f.bubble.should eq(Companion::GREETING) # her own hello, not the note that landed while she was off
      f.mood.should eq(:info)
    end
  end

  # "a re-enable starts a fresh idle window" (Companion#tick) has to hold for the beat-derived
  # state too — otherwise toggling her off mid-startle and back on resumes the startle.
  it "starts a fresh idle window on re-enable, not mid-schedule" do
    companion = Companion.new(Notifications.new)
    t0 = Time.instant
    with_companion(true) do
      companion.tick(t0)
      companion.tick(t0 + Companion::SLEEP_AFTER) # doze off
      woke = t0 + Companion::SLEEP_AFTER + 1.second
      companion.poke(woke) # …and arm the startle
      companion.tick(woke + Companion::BEAT)
      companion.frame.not_nil!.pose.should eq(:alert)
    end
    off = t0 + Companion::SLEEP_AFTER + 2.seconds
    with_companion(false) { companion.tick(off) } # disabled mid-startle
    with_companion(true) do
      companion.tick(off + 1.second)
      companion.frame.not_nil!.pose.should_not eq(:alert)
    end
  end

  it "blinks less often on calm than on lively" do
    t0 = Time.instant
    n = 300
    lively = with_companion(true, "lively") do
      companion = Companion.new(Notifications.new)
      companion.tick(t0)
      beats(companion, t0, n)
    end
    calm = with_companion(true, "calm") do
      companion = Companion.new(Notifications.new)
      companion.tick(t0)
      beats(companion, t0, n)
    end
    calm.should be < lively
  end

  # --- idle gestures --------------------------------------------------------

  # The feature itself — and it asserts the gestures arrive EARLY, not merely eventually.
  # @beat starts at 0 in every process, so this opening is not a sample of the schedule, it
  # IS the schedule as far as most sessions are concerned: the same fixed sequence for every
  # user of every build. A draw that is perfectly uniform in aggregate can still leave one
  # of the four unplayed across all of it, which is what the first draw did (the deadpan
  # first appeared 20 minutes in). 1300 beats is 4.3 minutes of AWAKE time — she dozes after
  # 90s, so a real session only gets there by someone actually working in gori.
  #
  # A sweep rather than hand-computed beat indices: the schedule is a pure function of the
  # beat so this replays identically every run, but pinning exact beats would re-break on
  # any retune of the shift or the odds.
  it "plays every idle gesture inside the first few minutes" do
    seen = Set(Symbol).new
    gesture_sweep(1300, "lively") { |f| seen << f.pose }
    Companion::GESTURES.flatten.uniq!.each { |pose| seen.should contain(pose) }
  end

  # "calm halves the blink rate and drops the rest" — the gestures are part of the rest.
  it "drops the gestures on calm, leaving her the blink" do
    seen = Set(Symbol).new
    gesture_sweep(6000, "calm") { |f| seen << f.pose }
    seen.should eq(Set{:idle, :blink})
  end

  # Mascot.cavity applies a wink to :idle and nothing else, so a Frame carrying one on any
  # other pose describes cells that are not painted — #tick would report a change the diff
  # then forwards nothing for. Held over the whole schedule, not just one beat.
  it "never asks for a wink the art would fold away" do
    folded = [] of Symbol
    gesture_sweep(6000, "lively") { |f| folded << f.pose if f.wink != :none && f.pose != :idle }
    folded.should be_empty
  end

  # …and the other half of that, which nothing asserted while both wink specs only said
  # where a wink may NOT appear: she must still wink. The gestures own the cavity whenever
  # one is running, so raising their rate takes winks away — silently, and in the same
  # direction as "more variety", which is what makes it worth pinning. Both sides in one
  # sweep so the ladder's two owners are counted against each other.
  it "still winks, on the idle face, alongside the gestures" do
    winks = 0
    gestures = 0
    gesture_sweep(6000, "lively") do |f|
      winks += 1 if f.wink != :none
      gestures += 1 if Companion::GESTURES.flatten.uniq!.includes?(f.pose) && f.pose != :blink
    end
    winks.should be > 0
    gestures.should be > 0
    # Neither track may crowd the other out: over 20 minutes of awake beats they stay
    # within an order of magnitude of each other.
    (winks * 10).should be > gestures
  end

  it "keeps every gesture script inside its window" do
    Companion::GESTURES.min_of(&.size).should be > 0
    Companion::GESTURES.max_of(&.size).should be <= Companion::GESTURE_MAX
    # …which is what bounds the hashed start offset, so it has to leave room for one.
    Companion::GESTURE_MAX.should be < (1 << Companion::GESTURE_SHIFT)
  end

  # Mascot.eyes and .mouth both fall through an `else` to the idle face, so a pose added to
  # the script table but not to BOTH tables renders as a gesture that never visibly happens.
  # Scoped to the gesture poses on purpose: asserting this across all of POSES would forbid
  # a future pose that differs only by badge or mood.
  it "gives every idle gesture a face of its own" do
    idle = Mascot.rows(Mascot::Frame.new)[1]
    rows = Companion::GESTURES.flatten.uniq!.map { |p| Mascot.rows(Mascot::Frame.new(pose: p))[1] }
    rows.each(&.should_not(eq(idle)))
    rows.uniq.size.should eq(rows.size)
  end

  # --- the greeting ---------------------------------------------------------

  it "says hello on the frame she first appears on" do
    with_companion(true) do
      companion = Companion.new(Notifications.new)
      t0 = Time.instant
      companion.tick(t0)
      f = companion.frame.not_nil!
      f.bubble.should eq(Companion::GREETING)
      f.mood.should eq(:info) # a hello is not a reaction — the face stays idle
      f.pose.should eq(:idle)
    end
  end

  it "holds the greeting longer than a note, then drops it" do
    with_companion(true) do
      companion = Companion.new(Notifications.new)
      t0 = Time.instant
      companion.tick(t0)
      # Past a note's TTL (3.5s) but still inside the greeting's.
      companion.tick(t0 + 5.seconds)
      companion.frame.not_nil!.bubble.should eq(Companion::GREETING)
      companion.tick(t0 + Companion::GREET_TTL + Companion::BEAT)
      companion.frame.not_nil!.bubble.should be_nil
    end
  end

  # Once per Companion, not once per enable edge: someone toggling her in the settings view to
  # see what she looks like is not asking to be greeted again each time.
  it "greets once, not on every re-enable" do
    companion = Companion.new(Notifications.new)
    t0 = Time.instant
    with_companion(true) { companion.tick(t0) }
    companion.frame.not_nil!.bubble.should eq(Companion::GREETING)
    with_companion(false) { companion.tick(t0 + Companion::BEAT) } # disable edge drops the frame and the bubble
    with_companion(true) do
      companion.tick(t0 + Companion::BEAT * 2)
      companion.frame.not_nil!.bubble.should be_nil
    end
  end

  it "does not greet while notices are off" do
    with_companion(true, notices: false) do
      companion = Companion.new(Notifications.new)
      companion.tick(Time.instant)
      companion.frame.not_nil!.bubble.should be_nil
    end
  end

  # The flag burns whether or not she was allowed to speak, so turning notices on an hour
  # into the session does not produce a stale hello.
  it "does not greet late when notices are turned on afterwards" do
    companion = Companion.new(Notifications.new)
    t0 = Time.instant
    with_companion(true, notices: false) { companion.tick(t0) }
    with_companion(true, notices: true) do
      beats(companion, t0, 3)
      companion.frame.not_nil!.bubble.should be_nil
    end
  end

  # The picker builds one Companion and the session it opens builds another, seconds apart —
  # one hello covers both, or the operator is greeted twice for one launch of gori.
  it "greets once per process, not once per Companion" do
    with_companion(true) do
      t0 = Time.instant
      first = Companion.new(Notifications.new)
      first.tick(t0)
      first.frame.not_nil!.bubble.should eq(Companion::GREETING)

      second = Companion.new(Notifications.new) # the session's, after a project is chosen
      second.tick(t0 + 5.seconds)
      second.frame.not_nil!.bubble.should be_nil
    end
  end

  # --- say (a line with no notification behind it) --------------------------

  it "says a line handed to it directly, with the level's mood" do
    with_companion(true) do
      companion = Companion.new(Notifications.new)
      t0 = Time.instant
      companion.tick(t0)
      companion.say("heads up: v9.9.9 is out", t0 + 1.second, :warn)
      companion.tick(t0 + 1.second + Companion::BEAT)
      f = companion.frame.not_nil!
      f.bubble.should eq("heads up: v9.9.9 is out") # replaces the hello it interrupts
      f.mood.should eq(:warn)
      companion.bubble_at.should eq(t0 + 1.second)
    end
  end

  # Same gate as the ring: Notices off means she does not speak, whoever is asking.
  it "stays silent on say while notices are off" do
    with_companion(true, notices: false) do
      companion = Companion.new(Notifications.new)
      t0 = Time.instant
      companion.tick(t0)
      companion.say("heads up: v9.9.9 is out", t0, :warn)
      companion.tick(t0 + Companion::BEAT)
      companion.frame.not_nil!.bubble.should be_nil
      companion.frame.not_nil!.mood.should eq(:info)
    end
  end

  it "wakes her from a doze to say it" do
    with_companion(true) do
      companion = Companion.new(Notifications.new)
      t0 = Time.instant
      companion.tick(t0)
      companion.tick(t0 + Companion::SLEEP_AFTER)
      companion.frame.not_nil!.pose.should eq(:doze)
      woke = t0 + Companion::SLEEP_AFTER + 1.second
      companion.say("heads up: v9.9.9 is out", woke, :warn)
      companion.tick(woke + Companion::BEAT)
      companion.frame.not_nil!.pose.should_not eq(:doze)
    end
  end

  # --- notifications --------------------------------------------------------

  it "announces a new note in a bubble and takes on its mood" do
    with_companion(true) do
      notes = Notifications.new
      companion = Companion.new(notes)
      t0 = Time.instant
      companion.tick(t0)
      notes.push(:success, "fuzzer: 3 hits on id")
      companion.tick(t0 + Companion::BEAT).should be_true
      f = companion.frame.not_nil!
      f.bubble.not_nil!.should contain("fuzzer")
      f.mood.should eq(:happy)
      f.pose.should eq(:happy)
    end
  end

  # A mood is held for three to five seconds — fifteen to twenty-five beats — so a single
  # frozen face reads as stuck rather than as reacting. Every reaction therefore plays a
  # peak and then settles into a quieter cousin of it.
  #
  # The ORDER is the half that matters and the half a lazy implementation gets wrong: the
  # peak has to be the face on the beat the note lands, or the settle stops being a tail on
  # something the operator saw and becomes a different first impression. So this asserts
  # both ends AND where the switch falls, rather than "the pose changes at some point".
  it "peaks on the beat a note lands, then settles for the rest of the hold" do
    [{:success, :happy, :smile}, {:warn, :alert, :hmm}, {:error, :error, :flat}].each do |level, peak, settled|
      with_companion(true) do
        notes = Notifications.new
        companion = Companion.new(notes)
        t0 = Time.instant
        companion.tick(t0)
        notes.push(level, "engine: something happened")
        # Stops inside the shortest mood hold (:happy, 3s = 15 beats), so nothing here is
        # the mood EXPIRING back to idle.
        poses = (1..Companion::REACT_PEAK + 4).map do |i|
          companion.tick(t0 + Companion::BEAT * i)
          companion.frame.not_nil!.pose
        end
        poses.first.should eq(peak)
        poses.last.should eq(settled)
        # …and the switch is where REACT_PEAK says it is: beat 1 is the first drawn beat of
        # the mood, so the settle starts at index REACT_PEAK - 1.
        poses.index(settled).should eq(Companion::REACT_PEAK - 1)
      end
    end
  end

  it "announces a note only once" do
    with_companion(true) do
      notes = Notifications.new
      companion = Companion.new(notes)
      t0 = Time.instant
      companion.tick(t0)
      notes.push(:info, "scan complete")
      companion.tick(t0 + Companion::BEAT).should be_true
      before = companion.frame
      companion.tick(t0 + Companion::BEAT + 1.millisecond).should be_false
      companion.frame.should eq(before)
    end
  end

  # :warning is pushed by repeater_controller and sequencer_controller even though the
  # documented level set is :warn — she must read both, not fall through to :info.
  it "maps the live :warning typo to the warn mood" do
    with_companion(true) do
      notes = Notifications.new
      companion = Companion.new(notes)
      t0 = Time.instant
      companion.tick(t0)
      notes.push(:warning, "repeater: aborted")
      companion.tick(t0 + Companion::BEAT)
      companion.frame.not_nil!.mood.should eq(:warn)
    end
  end

  it "does not re-announce after the ring buffer is cleared" do
    with_companion(true) do
      notes = Notifications.new
      companion = Companion.new(notes)
      t0 = Time.instant
      companion.tick(t0)
      notes.push(:info, "one")
      companion.tick(t0 + Companion::BEAT)
      notes.clear
      # latest_id drops to 0; the `id > seen` guard must read that as "nothing new".
      companion.tick(t0 + Companion::BEAT * 2)
      companion.frame.not_nil!.bubble.not_nil!.should eq("one")
    end
  end

  it "stays silent while notices are off" do
    with_companion(true, notices: false) do
      notes = Notifications.new
      companion = Companion.new(notes)
      t0 = Time.instant
      companion.tick(t0)
      notes.push(:error, "probe: boom")
      beats(companion, t0, 3)
      companion.frame.not_nil!.bubble.should be_nil
      companion.frame.not_nil!.mood.should eq(:info)
    end
  end

  # A burst of :info must not downgrade a live error reaction's FACE, but the newest
  # message still has to be the one on screen.
  it "keeps the higher-ranked face while replacing the bubble text" do
    with_companion(true) do
      notes = Notifications.new
      companion = Companion.new(notes)
      t0 = Time.instant
      companion.tick(t0)
      notes.push(:error, "probe: boom")
      companion.tick(t0 + Companion::BEAT)
      notes.push(:info, "history: 12 flows")
      companion.tick(t0 + Companion::BEAT * 2)
      f = companion.frame.not_nil!
      f.mood.should eq(:alarm)
      f.badge.should eq('×')
      f.bubble.not_nil!.should contain("history")
    end
  end

  it "expires the bubble" do
    with_companion(true) do
      notes = Notifications.new
      companion = Companion.new(notes)
      t0 = Time.instant
      companion.tick(t0)
      notes.push(:info, "scan complete")
      companion.tick(t0 + Companion::BEAT)
      companion.frame.not_nil!.bubble.should_not be_nil
      beats(companion, t0, 60) # well past every bubble TTL
      companion.frame.not_nil!.bubble.should be_nil
    end
  end

  # The bar placement shares the status row's single text slot with the toast, and Runner
  # picks between them by recency — which needs a timestamp on her side of the comparison.
  it "stamps when the bubble was set, and clears it with the bubble" do
    with_companion(true) do
      notes = Notifications.new
      companion = Companion.new(notes)
      t0 = Time.instant
      companion.tick(t0)
      companion.bubble_at.should eq(t0) # the greeting takes the bubble on the first frame
      notes.push(:info, "scan complete")
      companion.tick(t0 + Companion::BEAT)
      companion.bubble_at.should eq(t0 + Companion::BEAT)
      beats(companion, t0, 60) # past every TTL
      companion.frame.not_nil!.bubble.should be_nil
      companion.bubble_at.should be_nil
    end
  end

  it "condenses a multi-line message to one line" do
    with_companion(true) do
      notes = Notifications.new
      companion = Companion.new(notes)
      t0 = Time.instant
      companion.tick(t0)
      notes.push(:info, "first   line\there\nsecond line")
      companion.tick(t0 + Companion::BEAT)
      bubble = companion.frame.not_nil!.bubble.not_nil!
      bubble.should eq("first line here")
    end
  end

  # --- art integrity --------------------------------------------------------
  #
  # The sheet must stay honest as poses are added: every assembled row is exactly W
  # single-codepoint, single-column glyphs. A width-2 glyph slipping in would claim its
  # neighbour's cell and orphan-clear the one before it.

  it "assembles every pose x wink x badge to exactly W columns of width-1 glyphs" do
    badges = [nil, '·', '!', '×', 'z']
    Mascot::POSES.each do |pose|
      Mascot::WINKS.each do |wink|
        badges.each do |badge|
          frame = Mascot::Frame.new(pose: pose, wink: wink, badge: badge)
          Mascot.rows(frame).each do |row|
            row.size.should eq(Mascot::W)               # single codepoint per cell
            Screen.draw_width(row).should eq(Mascot::W) # …and one column each
          end
        end
      end
    end
  end

  # The whole point of this cut: three rows buy six units of height, so the equator has to
  # be six CELLS across or the hoop reads as an oval. That falls out of the half-block
  # walls, and a spec is the only thing that stops a future edit from widening it back.
  it "keeps the equator exactly as wide as the sprite is tall" do
    row = Mascot.rows(Mascot::Frame.new)[1]
    row[0].should eq(Mascot::WALL_L) # ▐ — inks the RIGHT half, x[0.5,1]
    row[6].should eq(Mascot::WALL_R) # ▌ — inks the LEFT half,  x[6,6.5]
    # 6.5 - 0.5 = 6.0 cells wide; 3 rows x 2 units = 6.0 units tall.
    (6.5 - 0.5).should eq(Mascot::H * 2.0)
  end

  # Every inked cell must resolve to a fg that differs from its bg, or the glyph is drawn
  # but invisible. This is exactly how the mouth shipped broken: the cell held ˘ while its
  # ink role still said "hole", which paints plate-on-plate. A tmux capture cannot catch
  # it — capture-pane returns the character buffer whatever colour it was painted in.
  it "never paints an inked cell in the background colour" do
    prev = Theme.active_name
    begin
      Theme.available.each do |name|
        Theme.apply(name)
        Mascot::POSES.each do |pose|
          frame = Mascot::Frame.new(pose: pose, badge: '!')
          pal = Mascot.palette(:info, Theme.bg)
          rows = Mascot.rows(frame)
          Mascot::H.times do |r|
            Mascot::W.times do |c|
              next if rows[r][c] == ' ' # a blank cell is allowed to be plate-on-plate
              fg, bg, _ = Mascot.role_style(Mascot::INK[r][c], pal)
              fg.should_not eq(bg)
            end
          end
        end
      end
    ensure
      Theme.apply(prev)
    end
  end

  # A combining-style diacritic is drawn at CAP HEIGHT — the same band the lashes occupy —
  # so a cup-shaped one like ˘ puts the mouth above the eyes instead of below them. That is
  # exactly how it shipped. Nothing about the glyph tables catches it, so pin it directly.
  it "never puts the mouth at cap height, where the lashes are" do
    Mascot::POSES.each do |pose|
      m = Mascot.mouth(pose)
      Mascot::CAP_HEIGHT_MARKS.includes?(m).should be_false
      Mascot::MOUTHS.includes?(m).should be_true
    end
    # …and the lashes are exactly the marks the mouth must avoid.
    Mascot::CAP_HEIGHT_MARKS.includes?(Mascot::LASH_L).should be_true
    Mascot::CAP_HEIGHT_MARKS.includes?(Mascot::LASH_R).should be_true
  end

  # The bar placement is a SLICE of the body sprite, not a second art table — if these ever
  # disagree the two placements have drifted.
  it "draws the bar chip from the body sprite's own middle row" do
    Mascot::POSES.each do |pose|
      frame = Mascot::Frame.new(pose: pose)
      Mascot.bar_label(frame).should eq(Mascot.rows(frame)[1][0, Mascot::BAR_W])
    end
  end

  # The chip run is ordered so the fixed-width clock anchors the right edge; a chip that
  # changes width would shift every readout to its left on each blink.
  it "keeps the bar chip a constant width across every pose and wink" do
    Mascot::POSES.each do |pose|
      Mascot::WINKS.each do |wink|
        label = Mascot.bar_label(Mascot::Frame.new(pose: pose, wink: wink))
        label.size.should eq(Mascot::BAR_W)
        Screen.draw_width(label).should eq(Mascot::BAR_W)
      end
    end
  end

  it "keeps the ink layer the same shape as the art" do
    Mascot::INK.size.should eq(Mascot::H)
    Mascot::INK.each(&.size.should eq(Mascot::W))
  end

  # She is a MISS, so she has lashes — on every pose, whichever way they lean. The brows
  # are an expression axis (Mascot.brows), so this asserts MEMBERSHIP rather than the
  # resting pair: what may never happen is a pose that drops one, which would leave a hole
  # cell painted plate-on-plate and shorten the face by a column.
  it "gives the Miss her lashes on every pose, whichever way they lean" do
    Mascot::POSES.each do |pose|
      cav = Mascot.cavity(pose, :none)
      [cav[0], cav[4]].each { |brow| {Mascot::LASH_L, Mascot::LASH_R}.includes?(brow).should be_true }
    end
    # …and the resting face is still the soft, open pairing: ´ left, ` right, both inner
    # ends up. The mirror of it is the stern read, so getting these two backwards would
    # ship a permanently cross mascot — see the LASH_L/LASH_R comments.
    Mascot.cavity(:idle, :none)[0].should eq(Mascot::LASH_L)
    Mascot.cavity(:idle, :none)[4].should eq(Mascot::LASH_R)
    Mascot.brows(:error).should eq({Mascot::LASH_R, Mascot::LASH_L})
  end

  # The rule the pose table is held to: a pose is only a pose if it looks like one. Every
  # entry has to differ from every other in the five cavity cells — brows, eyes, mouth —
  # because that is the entire vocabulary a pose has. A duplicate here is a face the
  # operator can never tell apart from another, and neither the art tables nor a tmux
  # capture of one frame would say so.
  it "gives every pose a face no other pose wears" do
    faces = Mascot::POSES.to_a.map { |pose| Mascot.cavity(pose, :none) }
    faces.uniq.size.should eq(Mascot::POSES.size)
  end

  # A wink is a gesture of the open-eyed idle pose; on a mood pose it would read as a
  # rendering glitch. EVERY other pose, not just :alert — this is the half of the invariant
  # that Companion#compose has to honour too, by never asking for a wink it would fold.
  it "only winks on the idle face" do
    Mascot.cavity(:idle, :left)[1].should eq('─')
    Mascot.cavity(:idle, :right)[3].should eq('─')
    Mascot::POSES.reject(:idle).each do |pose|
      Mascot::WINKS.each do |wink|
        Mascot.cavity(pose, wink).should eq(Mascot.cavity(pose, :none))
      end
    end
  end

  # --- palette --------------------------------------------------------------

  # The whole reason Theme.paper/soot exist. Shading with `blend(x, Theme.bg, t)` darkens
  # on a dark palette and LIGHTENS on a light one, so a highlight/shadow pair defined that
  # way silently inverts on roughly half the built-ins. Assert the ramp holds on EVERY
  # theme, because eyeballing one of them proves nothing about the other 29.
  it "keeps highlight brighter than shadow on every built-in theme" do
    prev = Theme.active_name
    begin
      Theme.available.each do |name|
        Theme.apply(name)
        pal = Mascot.palette(:info, Theme.bg)
        hi, ring, lo = Theme.luma(pal.hi), Theme.luma(pal.ring), Theme.luma(pal.lo)
        hi.should be > ring # lit side reads as lit …
        ring.should be > lo # … and the turned-away side as shadow
        # The pupils have to stay legible against the face plate they sit on.
        # The pupils sit in the HOLE, directly on the plate — that is the pair that has to
        # stay legible, and it is the one "make it brighter" gets wrong on light themes.
        (Theme.luma(pal.eye) - Theme.luma(pal.plate)).abs.should be > 0.25
        # …and the dimmed corner has to land between the band and the plate, or it stops
        # reading as a partly-covered pixel and just looks like a different colour.
        lo, hi = {Theme.luma(pal.ring), Theme.luma(pal.plate)}.minmax
        Theme.luma(pal.corner).should be >= lo
        Theme.luma(pal.corner).should be <= hi
      end
    ensure
      Theme.apply(prev)
    end
  end

  # --- rendering ------------------------------------------------------------

  describe ".draw" do
    # What Layout.compute yields for the body at 80x24.
    body = Rect.new(2, 4, 76, 18)

    it "lands in the bottom-right of the body and paints nothing outside it" do
      backend = MemoryBackend.new(80, 24)
      Companion.draw(Screen.new(backend), body, Mascot::Frame.new)
      rect = Companion.place(body).not_nil!
      # One clear row at the bottom: most tab bodies are a card whose bottom rule runs
      # along body.bottom - 1, and sitting on it cut the border in half.
      rect.bottom.should eq(body.bottom - Companion::BOTTOM_MARGIN)
      # The rows below and above her plate are untouched, and so is everything left of
      # the plate's padding.
      (rect.bottom..body.bottom).each { |y| backend.row(y).strip.should be_empty }
      backend.row(rect.y - 1).strip.should be_empty
      (Mascot::H).times do |i|
        backend.row(rect.y + i)[0, rect.x - 1].strip.should be_empty
      end
    end

    # The bug this reproduces: the gutter was sized for the SPRITE, but Companion.draw claims a
    # column of plate either side of it, so the right strip landed on the nested pane rule
    # and Repeater's Response pane lost its right border for her three rows. The outer
    # card's border one column further out survived, which is what made it read as a
    # rendering glitch rather than as occlusion.
    #
    # Driven by painting the rules FIRST and asserting they survive, rather than by pinning
    # the gutter to a number: the number is the thing that was wrong.
    #
    # SWEPT OVER THE SHAKE, because a still frame was not enough the second time either. The
    # gutter is sized for where she STANDS, and the :error reaction moves her — a frame with
    # shake: 1 put the right plate strip straight back on the nested rule, reopening the
    # exact bug below for the 200ms of that beat. Every offset Companion#shake_for can emit has to
    # hold the same invariant a still frame does.
    it "leaves both stacked pane rules intact, on the right and at the bottom" do
      (-1..1).each do |shake|
        backend = MemoryBackend.new(80, 24)
        screen = Screen.new(backend)
        # A sub-tabbed tab's shape: the outer card's rule on the body edge, and a nested
        # Frame.card's one cell inside it. Discover, Sitemap and Repeater all draw this.
        [1, 2].each do |inset|
          (body.y...body.bottom).each { |y| screen.cell(body.right - inset, y, '│', Theme.text, Theme.bg) }
          (body.x...body.right).each { |x| screen.cell(x, body.bottom - inset, '─', Theme.text, Theme.bg) }
        end
        Companion.draw(screen, body, Mascot::Frame.new(mood: :alarm, shake: shake))
        rect = Companion.place(body).not_nil!
        Mascot::H.times do |i|
          row = backend.row(rect.y + i)
          row[body.right - 1].should eq('│') # the outer card's rule
          row[body.right - 2].should eq('│') # …and the nested pane's, the one she ate
        end
        [1, 2].each do |inset|
          rule = backend.row(body.bottom - inset)
          # She can travel left, so the span she may occlude starts at her leftmost plate.
          (rect.x - 2..rect.right).each { |x| rule[x].should eq('─') }
        end
      end
    end

    # The shudder itself, at the source: an offset .draw would have to fold is an offset the
    # Frame is lying about, and #tick's field-wise compare would then report a change that
    # paints identical cells. Asserting on the emitted values (not on the painted grid) is
    # what pins that — the grid assertion above passes either way once .draw clamps.
    it "never asks to travel into the gutter it reserved" do
      with_companion(true) do
        notes = Notifications.new
        companion = Companion.new(notes)
        t0 = Time.instant
        companion.tick(t0)
        notes.push(:error, "upstream refused the connection")
        seen = (1..10).map do |i|
          companion.tick(t0 + Companion::BEAT * i)
          companion.frame.not_nil!.shake
        end
        seen.min.should be >= -1 # she stays inside the body
        seen.max.should eq(0)    # …and never travels toward the reserved right edge
        seen.should contain(-1)  # the shudder still plays
      end
    end

    # The only assertion that catches a width-2 glyph entering the sheet: such a glyph
    # claims x+1 as a continuation and orphan-clears the cell before it.
    it "never claims a continuation cell" do
      backend = MemoryBackend.new(80, 24)
      screen = Screen.new(backend)
      Mascot::POSES.each do |pose|
        Companion.draw(screen, body, Mascot::Frame.new(pose: pose, badge: '!'))
      end
      rect = Companion.place(body).not_nil!
      (Mascot::H).times do |i|
        (0...80).each { |x| backend.cont_grid[rect.y + i][x].should be_false }
      end
    end

    # The bubble used to stop growing at 34 columns, so a notice was cut with an '…' on an
    # 80-column terminal that had twice that free. Sweep the widths a real Layout produces
    # rather than pinning one number: the guarantees are monotonicity, the floor, the
    # ceiling, and never crossing the body.
    it "widens the bubble cap with the body, between its floor and its ceiling" do
      caps = [40, 60, 80, 100, 120, 160, 220].map do |cols|
        Companion.bubble_cap(Layout.compute(cols, 24).body.w)
      end
      caps.should eq(caps.sort)                                     # never narrower on a wider terminal
      caps.first.should eq(Companion::BUBBLE_BASE_W)                # the narrow end keeps today's width
      caps.last.should eq(Companion::BUBBLE_MAX_W)                  # …and a huge terminal stops at the ceiling
      Companion.bubble_cap(76).should be > Companion::BUBBLE_BASE_W # 80 cols, where she is actually read
    end

    # The fluid cap must not outgrow the narrow bodies the floor is above: at 40x24 the body
    # is 36, and BUBBLE_BASE_W alone would overhang it.
    it "keeps a wide bubble inside the body, floor included" do
      [40, 80, 120, 200].each do |cols|
        # NOT `body` — an `it` block closes over the describe-level local, and assigning to
        # it here would hand every later example a 200-column body on an 80x24 backend.
        wide = Layout.compute(cols, 24).body
        plate = Companion.place(wide).not_nil!
        box = Companion.bubble_box(wide, plate, "probe " * 60).not_nil!
        box.x.should be >= wide.x
        box.right.should be <= wide.right
        box.w.should be <= Companion.bubble_cap(wide.w)
      end
    end

    it "truncates a long bubble inside the body" do
      backend = MemoryBackend.new(80, 24)
      long = "probe " * 60
      Companion.draw(Screen.new(backend), body, Mascot::Frame.new(bubble: long))
      rect = Companion.place(body).not_nil!
      text_row = rect.y - Companion::BUBBLE_H + 1
      backend.row(text_row).should contain("…")
      (0...24).each do |y|
        Screen.draw_width(backend.row(y).rstrip).should be <= body.right
      end
    end

    # The width guard has to stay calibrated against what Layout can actually hand us:
    # Layout.usable? floors the terminal at 40x8 and Layout insets by H_PADDING, so the
    # narrowest real body is 36 — MIN_W must sit below that, or she would be hidden on a
    # terminal gori is perfectly happy to render.
    it "fits the narrowest body a real Layout can hand it" do
      floor = Layout.compute(40, 24).body
      floor.w.should eq(36)
      Companion::MIN_W.should be < floor.w
      rect = Companion.place(floor).not_nil!
      rect.w.should eq(Mascot::W)
      rect.right.should be <= floor.right - Companion::GUTTER
    end

    # Height is the live guard: body.h is height - 6 (or - 7 with the statusline).
    it "hides on a short terminal" do
      Companion.place(Layout.compute(120, 10).body).should be_nil
      Companion.place(Layout.compute(120, 24).body).should_not be_nil
    end

    it "paints nothing at all when the body is too small" do
      backend = MemoryBackend.new(80, 24)
      Companion.place(Rect.new(0, 0, Companion::MIN_W - 1, 10)).should be_nil
      Companion.draw(Screen.new(backend), Rect.new(0, 0, 20, 4), Mascot::Frame.new)
      backend.grid.each(&.all?(&.== ' ').should be_true)
    end
  end
end
