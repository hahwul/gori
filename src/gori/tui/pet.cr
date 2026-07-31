require "./mascot"
require "./notifications"
require "./frame"
require "./geometry"
require "./screen"
require "./theme"

module Gori::Tui
  # Miss Ring — the mascot in the bottom-right of the tab body. Owns WHEN she moves and
  # what she says; Mascot owns how she looks.
  #
  # IDLE-ZERO-CPU. The run loop only repaints when something reports `dirty`, so an
  # always-animating widget would defeat the design it lives in. Three layers keep that
  # honest:
  #
  #   1. She is OFF by default. A default install takes the first line of #tick and
  #      returns false, exactly like a disabled ResourceMeter.
  #   2. She DOZES. After SLEEP_AFTER with no key, no click and no notification she
  #      freezes into one static frame and #tick returns false forever — an unattended
  #      gori is back to genuinely zero animation work. #poke re-arms her.
  #   3. Even awake, #tick reports a change only when the frame that would be DRAWN
  #      differs — roughly 1 repaint/second on "lively", 0.3 on "calm", each forwarding
  #      a handful of changed cells through the backend's diff. Turning her on is an
  #      explicit opt-in to that, and the settings hint says so.
  #
  # SINGLE FIBER, NO LOCKS — the same invariant Notifications documents. #tick runs on
  # the render loop, #poke on the input handler, .draw on render; all the main fiber. The
  # engines push notes from their own fibers into channels that the MAIN fiber drains, so
  # a controller worker must never touch a Pet.
  class Pet
    # Evaluation cadence. NOT the redraw cadence — see #advance.
    BEAT = 200.milliseconds

    # No key, no click, no note for this long and she falls asleep (and stops ticking).
    SLEEP_AFTER = 90.seconds

    # Idle-track windows, as a shift of the beat counter: 2^n beats per window.
    BLINK_SHIFT = 4 #  16 beats = 3.2s
    WINK_SHIFT  = 6 #  64 beats = 12.8s
    GLINT_SHIFT = 7 # 128 beats = 25.6s

    # Beats she stays startled after being woken from a doze.
    WAKE_BEATS = 3

    # Reaction severity. A new note may take the face only if it ranks at or above the
    # live one — a burst of :info must not stomp on an error reaction.
    RANK = {:info => 0, :happy => 1, :warn => 2, :alarm => 3}

    # Her one unprompted line — see #greet. Everything else she says is a notification
    # someone else raised.
    GREETING = "hi! ready when you are"
    # Held longer than a notification bubble (3.5s). A note is a reaction to something
    # the operator just did, so they are already looking at her corner; the hello lands
    # while the tab body is still painting and their eyes are on the tab bar.
    GREET_TTL = 8.seconds

    # Sprite geometry within the body.
    #
    # Calibrated against the REAL floor: Layout.usable? refuses to render below 40x8, and
    # Layout insets by H_PADDING/V_PADDING, so the smallest body this can ever be handed is
    # 36 wide — against which the sprite plus its gutter is 11 columns. MIN_W is therefore a
    # defensive guard for non-Layout callers (and the specs) rather than something a user
    # reaches. Height is the live constraint (body.h is height - 6, so 6 needs 12 rows).
    MIN_W = 30
    MIN_H =  6
    # Columns kept clear at the body's right edge: the same two rules BOTTOM_MARGIN clears
    # (a pane hairline at body.right - 1 and a nested Frame.card's at body.right - 2, which
    # doubles as Frame.scroll_gauge's thumb column), PLUS ONE for the plate strip.
    #
    # That last column is the whole reason this is 3 and not 2. Pet.draw claims a column of
    # plate either side of the sprite, so the box it actually paints is Mascot::W + 2 wide,
    # not Mascot::W — and a gutter sized for the sprite alone put the right strip exactly on
    # the nested rule. It showed up as Repeater's Response pane losing its right border for
    # the three rows she occupies, while the outer card's border one column further out
    # survived: a single missing hairline, which reads as a rendering bug.
    #
    # The vertical side needs no such term because the plate strips are left/right only.
    GUTTER = 3
    # …and TWO rows at the bottom, for the same reason. She occludes body content by
    # design, but a chewed BORDER reads as a rendering bug rather than as a mascot, and
    # tab bodies stack up to two rules there: the pane's own at body.bottom - 1, plus a
    # nested Frame.card's at body.bottom - 2 on the sub-tabbed tabs (Discover, Sitemap,
    # Repeater…). Clearing both is the difference between "───  ▝▄▄▄▄▄▘  ╯" and a mascot
    # sitting inside the pane.
    BOTTOM_MARGIN = 2

    BUBBLE_H     =  3
    BUBBLE_MIN_W = 14 # narrower than this is unreadable — drop the bubble, keep the pose
    BUBBLE_MAX_W = 34

    getter frame : Mascot::Frame?
    # When the live bubble was set. The bar placement shares the status row's single text
    # slot with the toast, and the two are resolved by recency (Runner#pet_notice).
    getter bubble_at : Time::Instant?

    def initialize(@notes : Notifications)
      @frame = nil.as(Mascot::Frame?)
      @beat = 0
      @last_beat = nil.as(Time::Instant?)
      @last_poke = nil.as(Time::Instant?)
      @dozing = false
      @wake_until_beat = 0
      @settle_beat = -1
      @seen_id = @notes.latest_id # don't announce a backlog on enable
      @greeted = false
      @bubble = nil.as(String?)
      @bubble_at = nil.as(Time::Instant?)
      @bubble_until = nil.as(Time::Instant?)
      @mood = :info
      @mood_beat = 0
      @mood_until = nil.as(Time::Instant?)
    end

    # Advance the animation, pick up new notifications, and report whether the DRAWN frame
    # changed. Same contract as ResourceMeter#tick and the top-bar clock: a beat that lands
    # on an identical frame is silent, so the run loop never repaints on a bare timer.
    def tick(now : Time::Instant) : Bool
      unless Settings.pet?
        # Disable edge, as in ResourceMeter#tick: drop the frame ONCE, then stay silent.
        # Clearing the timers also means a re-enable starts a fresh idle window rather
        # than waking up mid-schedule.
        return false if @frame.nil?
        reset
        return true
      end
      # ENABLE edge (no frame yet: freshly constructed, or just switched back on). Baseline
      # the notification watermark here rather than trusting whatever it held while she was
      # hidden — otherwise everything that landed in the meantime is still "new" and she
      # announces a stale result as though it had just happened. Deliberately swallows a
      # note that arrives on this very tick too: "don't announce a backlog on enable".
      if @frame.nil?
        @seen_id = @notes.latest_id
        greet(now)
      end
      @last_poke ||= now
      changed = consume_note(now)
      changed = true if expire_bubble(now)
      changed = true if expire_mood(now)
      changed = true if advance(now)
      changed
    end

    # Any sign of life re-arms the idle clock and wakes her if she had dozed off.
    def poke(now : Time::Instant) : Nil
      @last_poke = now
      return unless @dozing
      @dozing = false
      @last_beat = now
      @wake_until_beat = @beat + WAKE_BEATS
    end

    # Wake hook for the input path. Self-gated so a keystroke costs nothing at all while
    # she's disabled — the run loop calls this on every key and click.
    def wake_on_input : Nil
      return unless Settings.pet?
      poke(Time.instant)
    end

    # Back to the state a freshly-constructed Pet is in. The BEAT-DERIVED deadlines have to
    # go too, not just the timers: @wake_until_beat and @settle_beat are compared against
    # @beat, which reset does not rewind, so leaving them set means disabling her mid-startle
    # (or on the settle beat after a reaction) and switching back on resumes that pose
    # instead of the fresh idle window this promises.
    private def reset : Nil
      @frame = nil
      @last_beat = nil
      @last_poke = nil
      @dozing = false
      @wake_until_beat = @beat
      @settle_beat = -1
      @mood_beat = @beat
      @bubble = nil
      @bubble_at = nil
      @bubble_until = nil
      @mood = :info
      @mood_until = nil
      @seen_id = @notes.latest_id
    end

    # --- the beat clock ------------------------------------------------------

    private def advance(now : Time::Instant) : Bool
      return false if @dozing # asleep: the static frame is already drawn, do nothing
      if last = @last_beat
        # NOT `last + BEAT`: after a stall (a modal held open, the process suspended) she
        # resumes from now rather than burst-catching-up through every missed beat.
        return false if now - last < BEAT
        @last_beat = now
        @beat &+= 1
      else
        @last_beat = now
      end
      check_doze(now)
      next_frame = compose
      return false if next_frame == @frame
      @frame = next_frame
      true
    end

    private def check_doze(now : Time::Instant) : Nil
      return if @dozing
      poke = @last_poke
      return unless poke && now - poke >= SLEEP_AFTER
      @dozing = true
    end

    # The frame to draw. A pure function of @beat and the mood/bubble state — never of the
    # wall clock — or the same beat could yield two different frames and the diff would
    # stop being meaningful (or specifiable).
    private def compose : Mascot::Frame
      if @dozing
        return Mascot::Frame.new(pose: :doze, badge: 'z', mood: :doze, bubble: @bubble)
      end
      if @beat < @wake_until_beat
        # Startled awake, then settles.
        return Mascot::Frame.new(pose: :alert, badge: '·', bubble: @bubble)
      end
      mood = @mood
      Mascot::Frame.new(
        pose: pose_for(mood),
        wink: mood == :info ? wink_for : :none,
        badge: badge_for(mood),
        glint: glint_for,
        mood: mood,
        bubble: @bubble,
        shake: shake_for(mood),
      )
    end

    private def pose_for(mood : Symbol) : Symbol
      case mood
      when :happy then :happy
      when :warn  then :alert
      when :alarm then :error # ×_× — its own face now, not :alert with a different badge
      else
        # The settle beat right after a reaction expires reads as her composing herself.
        @beat == @settle_beat || blink? ? :blink : :idle
      end
    end

    private def badge_for(mood : Symbol) : Char?
      case mood
      when :happy then '·'
      when :warn  then '!'
      when :alarm then '×'
      end
    end

    # The :error reaction gets a three-beat shudder; every other mood sits still.
    private def shake_for(mood : Symbol) : Int32
      return 0 unless mood == :alarm
      case @beat - @mood_beat
      when 0 then -1
      when 1 then 1
      else        0
      end
    end

    # --- idle tracks ---------------------------------------------------------
    #
    # Randomness without Random: a pure hash of the WINDOW index, following the project
    # picker's star_hash. No state to seed, snapshot or drift, and a spec can replay the
    # exact same schedule.

    def self.beat_hash(n : Int32, salt : UInt32) : UInt32
      h = (n.to_u32! &* 0x9E3779B1_u32) ^ (salt &* 0x85EBCA77_u32)
      h ^= h >> 15
      h &*= 0xC2B2AE3D_u32
      h ^ (h >> 13)
    end

    private def window(shift : Int32, salt : UInt32) : {UInt32, Int32}
      win = @beat >> shift
      {Pet.beat_hash(win, salt), @beat & ((1 << shift) - 1)}
    end

    # One blink per window at a hashed offset, plus a double-blink in one window in four.
    # On "calm" the window doubles, so she blinks half as often.
    private def blink? : Bool
      shift = Settings.pet_lively? ? BLINK_SHIFT : BLINK_SHIFT + 1
      h, off = window(shift, 1_u32)
      at = (h % 13).to_i
      return true if off == at
      ((h >> 8) & 3) == 0 && off == at + 2
    end

    # A wink in one window in three, 2 beats long, side chosen by the hash. This is what
    # replaced a gaze slide: the lashes occupy the outer face cells, so the eye pair has
    # nowhere left to slide — and a wink suits her better anyway.
    private def wink_for : Symbol
      return :none unless Settings.pet_lively?
      h, off = window(WINK_SHIFT, 2_u32)
      return :none unless h % 3 == 0
      at = ((h >> 6) % 56).to_i
      return :none unless off >= at && off < at + 2
      ((h >> 3) & 1) == 0 ? :left : :right
    end

    # The specular walks GLINT_PATH one cell per two beats — polished gold turning under a
    # light. Two cells change, which is why this and not a vertical bob: a bob would
    # rewrite the whole plate every beat and visibly jitter against the body text.
    private def glint_for : Int32
      return -1 unless Settings.pet_lively?
      h, off = window(GLINT_SHIFT, 3_u32)
      at = ((h >> 4) % 116).to_i
      d = off - at
      return -1 if d < 0 || d >= Mascot::GLINT_PATH.size * 2
      d // 2
    end

    # --- notifications -------------------------------------------------------

    # Say hello the first time she appears. ONCE per Pet, not once per enable edge: the
    # Runner holds one for the whole session, and someone flipping her on and off in the
    # settings view to see what she looks like is not asking to be greeted each time.
    #
    # Gated on `notices` like everything else she says — a reader who turned her speech
    # off asked for a silent mascot — and it burns the flag either way, so turning
    # notices on an hour later does not produce a stale hello. The mood stays :info: a
    # mood is a reaction to a note's LEVEL, and a greeting has none.
    private def greet(now : Time::Instant) : Nil
      return if @greeted
      @greeted = true
      return unless Settings.pet_notices?
      @bubble = GREETING
      @bubble_at = now
      @bubble_until = now + GREET_TTL
    end

    private def consume_note(now : Time::Instant) : Bool
      id = @notes.latest_id
      return false if id <= @seen_id # empty, unchanged, or post-clear
      @seen_id = id
      return false unless note = @notes.latest
      return false unless Settings.pet_notices?
      @bubble = condense(note.message)
      @bubble_at = now
      @bubble_until = now + bubble_ttl(mood_of(note.level))
      apply_mood(mood_of(note.level), now)
      poke(now) # a result is worth waking up for
      true
    end

    private def mood_of(level : Symbol) : Symbol
      case level
      when :success        then :happy
      when :warn, :warning then :warn # :warning is a live typo at two push sites
      when :error          then :alarm
      else                      :info
      end
    end

    # A lower-ranked note always replaces the bubble TEXT (the newest message must be the
    # one on screen) but never downgrades a live reaction's FACE.
    private def apply_mood(mood : Symbol, now : Time::Instant) : Nil
      if (until_ = @mood_until) && RANK[mood] < RANK[@mood] && now < until_
        return # a live higher-ranked reaction keeps the face
      end
      @mood = mood
      @mood_beat = @beat
      @mood_until = mood == :info ? nil : now + mood_hold(mood)
    end

    private def mood_hold(mood : Symbol) : Time::Span
      case mood
      when :happy then 3.seconds
      when :warn  then 4.seconds
      when :alarm then 5.seconds
      else             0.seconds
      end
    end

    private def bubble_ttl(mood : Symbol) : Time::Span
      case mood
      when :warn  then 5.seconds
      when :alarm then 6.seconds
      else             3500.milliseconds
      end
    end

    private def expire_bubble(now : Time::Instant) : Bool
      return false unless until_ = @bubble_until
      return false if now < until_
      @bubble = nil
      @bubble_at = nil
      @bubble_until = nil
      true
    end

    private def expire_mood(now : Time::Instant) : Bool
      return false unless until_ = @mood_until
      return false if now < until_
      @mood = :info
      @mood_until = nil
      @settle_beat = @beat + 1
      true
    end

    # First line only, control bytes dropped, whitespace squeezed. The result is stored
    # UNTRUNCATED — the column clamp happens in .draw, so a resize is not an animation
    # change.
    private def condense(msg : String) : String
      line = msg.each_line.first? || ""
      line.gsub { |c| c.control? ? ' ' : c }.split.join(' ')
    end

    # --- geometry + rendering (pure; explicit Frame, so specs need no clock) ----

    # Where the 8x3 sprite grid lands, or nil when the body is too small for her at all.
    # Nothing is cached — this is recomputed from the live body every frame, so a resize
    # needs no invalidation.
    def self.place(body : Rect) : Rect?
      return nil if body.w < MIN_W || body.h < MIN_H
      x = body.right - GUTTER - Mascot::W
      y = body.bottom - Mascot::H - BOTTOM_MARGIN
      return nil if x < body.x || y < body.y
      Rect.new(x, y, Mascot::W, Mascot::H)
    end

    # Above the sprite, right-aligned to it, tail pointing down at her cap. Above rather
    # than beside because the body's right edge is a pane border or a scroll gauge, and a
    # side bubble would cover the list rows the user is actually reading.
    def self.bubble_box(body : Rect, plate : Rect, msg : String) : Rect?
      cap = {BUBBLE_MAX_W, body.w - 4}.min
      return nil if cap < BUBBLE_MIN_W
      want = {Screen.display_width(msg) + 4, BUBBLE_MIN_W}.max
      w = {want, cap}.min
      x = {plate.right - w, body.x + 1}.max
      y = plate.y - BUBBLE_H
      return nil if y < body.y
      Rect.new(x, y, w, BUBBLE_H)
    end

    def self.draw(screen : Screen, body : Rect, frame : Mascot::Frame) : Nil
      return unless rect = place(body)
      pal = Mascot.palette(frame.mood, Theme.bg)

      if msg = frame.bubble
        if box = bubble_box(body, rect, msg)
          draw_bubble(screen, box, msg, rect, pal)
        end
      end

      # Shake the plate, clamped so she can never walk out of the body.
      x = (rect.x + frame.shake).clamp(body.x, body.right - rect.w)
      # A column of plate either side so she never butts against body text. Only the two
      # STRIPS — Mascot.draw already claims every cell it covers opaquely, so filling the
      # whole box first would rewrite cells that are about to be overwritten, on every
      # frame she is drawn (which is every frame, not just the ones where she moves).
      rect.h.times do |i|
        screen.cell(x - 1, rect.y + i, ' ', pal.plate, pal.plate) if x - 1 >= body.x
        r = x + rect.w
        screen.cell(r, rect.y + i, ' ', pal.plate, pal.plate) if r < body.right
      end
      Mascot.draw(screen, x, rect.y, frame, pal)
    end

    private def self.draw_bubble(screen : Screen, box : Rect, msg : String,
                                 plate : Rect, pal : Mascot::Palette) : Nil
      Tui::Frame.card(screen, box, bg: Theme.elevated, border: pal.ring)
      # Screen#text already does grapheme-aware truncation with a trailing '…' — hand-rolled
      # clipping here is how the width bugs (#278/#285) happened in the first place.
      screen.text(box.x + 2, box.y + 1, msg, Theme.text_bright, Theme.elevated,
        width: box.w - 4)
      # Tail: one '─' of the bottom rule becomes '┬' over her cap, clamped inside the
      # corners so it can never eat a ╰ or ╯.
      tail = (plate.x + 4).clamp(box.x + 2, box.right - 3)
      screen.cell(tail, box.bottom - 1, '┬', pal.ring, Theme.elevated)
    end
  end
end
