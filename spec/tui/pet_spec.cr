require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# Runs `block` with Miss Ring forced on/off (and a motion mode), restoring both.
private def with_pet(enabled : Bool, motion : String = "lively", notices : Bool = true, &)
  prev = {Gori::Settings.pet?, Gori::Settings.pet_motion, Gori::Settings.pet_notices?}
  Gori::Settings.pet = enabled
  Gori::Settings.pet_motion = motion
  Gori::Settings.pet_notices = notices
  begin
    yield
  ensure
    Gori::Settings.pet = prev[0]
    Gori::Settings.pet_motion = prev[1]
    Gori::Settings.pet_notices = prev[2]
  end
end

# Step the pet forward `n` beats from `t0`, returning how many of those ticks reported a
# change. Beats are stepped one at a time because #advance re-bases on `now`, not on
# last + BEAT — a single jump would collapse the whole span into one beat.
private def beats(pet : Pet, t0 : Time::Instant, n : Int32) : Int32
  (1..n).count { |i| pet.tick(t0 + Pet::BEAT * i) }
end

describe Gori::Tui::Pet do
  # --- the tick contract (idle-zero-CPU) ------------------------------------

  it "does nothing while disabled" do
    with_pet(false) do
      pet = Pet.new(Notifications.new)
      pet.tick(Time.instant).should be_false
      pet.frame.should be_nil
    end
  end

  it "produces an idle frame on the first tick" do
    with_pet(true) do
      pet = Pet.new(Notifications.new)
      pet.tick(Time.instant).should be_true
      pet.frame.not_nil!.pose.should eq(:idle)
    end
  end

  it "does not re-compose before a beat elapses" do
    with_pet(true) do
      pet = Pet.new(Notifications.new)
      t0 = Time.instant
      pet.tick(t0).should be_true
      pet.tick(t0 + Pet::BEAT - 1.millisecond).should be_false
    end
  end

  # The repaint budget the feature is sold on: awake and quiet, she must change the drawn
  # frame only a handful of times per minute — NOT once per beat. Asserted as a rate so
  # retuning the schedule constants doesn't require editing a hardcoded count.
  it "changes the drawn frame far less often than it beats" do
    with_pet(true) do
      pet = Pet.new(Notifications.new)
      t0 = Time.instant
      pet.tick(t0)
      n = (Pet::SLEEP_AFTER.total_milliseconds / Pet::BEAT.total_milliseconds).to_i - 1
      changed = beats(pet, t0, n)
      changed.should be > 0                 # she is not frozen
      changed.should be < (n * 3 / 10).to_i # …but well under a third of the beats
    end
  end

  # THE idle-zero-CPU test. After SLEEP_AFTER with no poke she must transition to :doze
  # exactly once and then report nothing, forever.
  it "dozes off and then stops reporting entirely" do
    with_pet(true) do
      pet = Pet.new(Notifications.new)
      t0 = Time.instant
      pet.tick(t0)
      pet.tick(t0 + Pet::SLEEP_AFTER).should be_true
      pet.frame.not_nil!.pose.should eq(:doze)
      pet.frame.not_nil!.badge.should eq('z') # reads as asleep, not as a hang
      pet.tick(t0 + Pet::SLEEP_AFTER + Pet::BEAT).should be_false
      pet.tick(t0 + 1.hour).should be_false
    end
  end

  it "wakes from a doze on input and settles back to idle" do
    with_pet(true) do
      pet = Pet.new(Notifications.new)
      t0 = Time.instant
      pet.tick(t0)
      pet.tick(t0 + Pet::SLEEP_AFTER)
      woke = t0 + Pet::SLEEP_AFTER + 1.second
      pet.poke(woke)
      pet.tick(woke + Pet::BEAT).should be_true
      pet.frame.not_nil!.pose.should eq(:alert) # startled
      beats(pet, woke, Pet::WAKE_BEATS + 2)
      pet.frame.not_nil!.pose.should_not eq(:doze)
    end
  end

  it "drops the frame once on the disable edge, then stays quiet" do
    pet = Pet.new(Notifications.new)
    with_pet(true) { pet.tick(Time.instant).should be_true }
    with_pet(false) do
      pet.tick(Time.instant).should be_true
      pet.frame.should be_nil
      pet.tick(Time.instant).should be_false
    end
  end

  # The watermark has to stay current while she is OFF, or enabling her mid-session
  # replays whatever landed in the meantime as if it just happened.
  it "does not announce a backlog accumulated while she was off" do
    notes = Notifications.new
    pet = Pet.new(notes)
    t0 = Time.instant
    with_pet(false) { pet.tick(t0) }
    notes.push(:error, "probe: boom") # arrives while she is hidden
    with_pet(true) do
      pet.tick(t0 + Pet::BEAT)
      f = pet.frame.not_nil!
      f.bubble.should eq(Pet::GREETING) # her own hello, not the note that landed while she was off
      f.mood.should eq(:info)
    end
  end

  # "a re-enable starts a fresh idle window" (Pet#tick) has to hold for the beat-derived
  # state too — otherwise toggling her off mid-startle and back on resumes the startle.
  it "starts a fresh idle window on re-enable, not mid-schedule" do
    pet = Pet.new(Notifications.new)
    t0 = Time.instant
    with_pet(true) do
      pet.tick(t0)
      pet.tick(t0 + Pet::SLEEP_AFTER) # doze off
      woke = t0 + Pet::SLEEP_AFTER + 1.second
      pet.poke(woke) # …and arm the startle
      pet.tick(woke + Pet::BEAT)
      pet.frame.not_nil!.pose.should eq(:alert)
    end
    off = t0 + Pet::SLEEP_AFTER + 2.seconds
    with_pet(false) { pet.tick(off) } # disabled mid-startle
    with_pet(true) do
      pet.tick(off + 1.second)
      pet.frame.not_nil!.pose.should_not eq(:alert)
    end
  end

  it "blinks less often on calm than on lively" do
    t0 = Time.instant
    n = 300
    lively = with_pet(true, "lively") do
      pet = Pet.new(Notifications.new)
      pet.tick(t0)
      beats(pet, t0, n)
    end
    calm = with_pet(true, "calm") do
      pet = Pet.new(Notifications.new)
      pet.tick(t0)
      beats(pet, t0, n)
    end
    calm.should be < lively
  end

  # --- the greeting ---------------------------------------------------------

  it "says hello on the frame she first appears on" do
    with_pet(true) do
      pet = Pet.new(Notifications.new)
      t0 = Time.instant
      pet.tick(t0)
      f = pet.frame.not_nil!
      f.bubble.should eq(Pet::GREETING)
      f.mood.should eq(:info) # a hello is not a reaction — the face stays idle
      f.pose.should eq(:idle)
    end
  end

  it "holds the greeting longer than a note, then drops it" do
    with_pet(true) do
      pet = Pet.new(Notifications.new)
      t0 = Time.instant
      pet.tick(t0)
      # Past a note's TTL (3.5s) but still inside the greeting's.
      pet.tick(t0 + 5.seconds)
      pet.frame.not_nil!.bubble.should eq(Pet::GREETING)
      pet.tick(t0 + Pet::GREET_TTL + Pet::BEAT)
      pet.frame.not_nil!.bubble.should be_nil
    end
  end

  # Once per Pet, not once per enable edge: someone toggling her in the settings view to
  # see what she looks like is not asking to be greeted again each time.
  it "greets once, not on every re-enable" do
    pet = Pet.new(Notifications.new)
    t0 = Time.instant
    with_pet(true) { pet.tick(t0) }
    pet.frame.not_nil!.bubble.should eq(Pet::GREETING)
    with_pet(false) { pet.tick(t0 + Pet::BEAT) } # disable edge drops the frame and the bubble
    with_pet(true) do
      pet.tick(t0 + Pet::BEAT * 2)
      pet.frame.not_nil!.bubble.should be_nil
    end
  end

  it "does not greet while notices are off" do
    with_pet(true, notices: false) do
      pet = Pet.new(Notifications.new)
      pet.tick(Time.instant)
      pet.frame.not_nil!.bubble.should be_nil
    end
  end

  # The flag burns whether or not she was allowed to speak, so turning notices on an hour
  # into the session does not produce a stale hello.
  it "does not greet late when notices are turned on afterwards" do
    pet = Pet.new(Notifications.new)
    t0 = Time.instant
    with_pet(true, notices: false) { pet.tick(t0) }
    with_pet(true, notices: true) do
      beats(pet, t0, 3)
      pet.frame.not_nil!.bubble.should be_nil
    end
  end

  # --- notifications --------------------------------------------------------

  it "announces a new note in a bubble and takes on its mood" do
    with_pet(true) do
      notes = Notifications.new
      pet = Pet.new(notes)
      t0 = Time.instant
      pet.tick(t0)
      notes.push(:success, "fuzzer: 3 hits on id")
      pet.tick(t0 + Pet::BEAT).should be_true
      f = pet.frame.not_nil!
      f.bubble.not_nil!.should contain("fuzzer")
      f.mood.should eq(:happy)
      f.pose.should eq(:happy)
    end
  end

  it "announces a note only once" do
    with_pet(true) do
      notes = Notifications.new
      pet = Pet.new(notes)
      t0 = Time.instant
      pet.tick(t0)
      notes.push(:info, "scan complete")
      pet.tick(t0 + Pet::BEAT).should be_true
      before = pet.frame
      pet.tick(t0 + Pet::BEAT + 1.millisecond).should be_false
      pet.frame.should eq(before)
    end
  end

  # :warning is pushed by repeater_controller and sequencer_controller even though the
  # documented level set is :warn — she must read both, not fall through to :info.
  it "maps the live :warning typo to the warn mood" do
    with_pet(true) do
      notes = Notifications.new
      pet = Pet.new(notes)
      t0 = Time.instant
      pet.tick(t0)
      notes.push(:warning, "repeater: aborted")
      pet.tick(t0 + Pet::BEAT)
      pet.frame.not_nil!.mood.should eq(:warn)
    end
  end

  it "does not re-announce after the ring buffer is cleared" do
    with_pet(true) do
      notes = Notifications.new
      pet = Pet.new(notes)
      t0 = Time.instant
      pet.tick(t0)
      notes.push(:info, "one")
      pet.tick(t0 + Pet::BEAT)
      notes.clear
      # latest_id drops to 0; the `id > seen` guard must read that as "nothing new".
      pet.tick(t0 + Pet::BEAT * 2)
      pet.frame.not_nil!.bubble.not_nil!.should eq("one")
    end
  end

  it "stays silent while notices are off" do
    with_pet(true, notices: false) do
      notes = Notifications.new
      pet = Pet.new(notes)
      t0 = Time.instant
      pet.tick(t0)
      notes.push(:error, "probe: boom")
      beats(pet, t0, 3)
      pet.frame.not_nil!.bubble.should be_nil
      pet.frame.not_nil!.mood.should eq(:info)
    end
  end

  # A burst of :info must not downgrade a live error reaction's FACE, but the newest
  # message still has to be the one on screen.
  it "keeps the higher-ranked face while replacing the bubble text" do
    with_pet(true) do
      notes = Notifications.new
      pet = Pet.new(notes)
      t0 = Time.instant
      pet.tick(t0)
      notes.push(:error, "probe: boom")
      pet.tick(t0 + Pet::BEAT)
      notes.push(:info, "history: 12 flows")
      pet.tick(t0 + Pet::BEAT * 2)
      f = pet.frame.not_nil!
      f.mood.should eq(:alarm)
      f.badge.should eq('×')
      f.bubble.not_nil!.should contain("history")
    end
  end

  it "expires the bubble" do
    with_pet(true) do
      notes = Notifications.new
      pet = Pet.new(notes)
      t0 = Time.instant
      pet.tick(t0)
      notes.push(:info, "scan complete")
      pet.tick(t0 + Pet::BEAT)
      pet.frame.not_nil!.bubble.should_not be_nil
      beats(pet, t0, 60) # well past every bubble TTL
      pet.frame.not_nil!.bubble.should be_nil
    end
  end

  # The bar placement shares the status row's single text slot with the toast, and Runner
  # picks between them by recency — which needs a timestamp on her side of the comparison.
  it "stamps when the bubble was set, and clears it with the bubble" do
    with_pet(true) do
      notes = Notifications.new
      pet = Pet.new(notes)
      t0 = Time.instant
      pet.tick(t0)
      pet.bubble_at.should eq(t0) # the greeting takes the bubble on the first frame
      notes.push(:info, "scan complete")
      pet.tick(t0 + Pet::BEAT)
      pet.bubble_at.should eq(t0 + Pet::BEAT)
      beats(pet, t0, 60) # past every TTL
      pet.frame.not_nil!.bubble.should be_nil
      pet.bubble_at.should be_nil
    end
  end

  it "condenses a multi-line message to one line" do
    with_pet(true) do
      notes = Notifications.new
      pet = Pet.new(notes)
      t0 = Time.instant
      pet.tick(t0)
      notes.push(:info, "first   line\there\nsecond line")
      pet.tick(t0 + Pet::BEAT)
      bubble = pet.frame.not_nil!.bubble.not_nil!
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

  it "gives the Miss her lashes on every pose" do
    Mascot::POSES.each do |pose|
      cav = Mascot.cavity(pose, :none)
      cav[0].should eq(Mascot::LASH_L)
      cav[4].should eq(Mascot::LASH_R)
    end
  end

  # A wink is a gesture of the open-eyed idle pose; on a mood pose it would read as a
  # rendering glitch.
  it "only winks on the idle face" do
    Mascot.cavity(:idle, :left)[1].should eq('─')
    Mascot.cavity(:idle, :right)[3].should eq('─')
    Mascot.cavity(:alert, :left).should eq(Mascot.cavity(:alert, :none))
  end

  # --- palette --------------------------------------------------------------

  # The whole reason Theme.paper/soot exist. Shading with `blend(x, Theme.bg, t)` darkens
  # on a dark palette and LIGHTENS on a light one, so a highlight/shadow pair defined that
  # way silently inverts on roughly half the built-ins. Assert the ramp holds on EVERY
  # theme, because eyeballing one of them proves nothing about the other 27.
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
      Pet.draw(Screen.new(backend), body, Mascot::Frame.new)
      rect = Pet.place(body).not_nil!
      # One clear row at the bottom: most tab bodies are a card whose bottom rule runs
      # along body.bottom - 1, and sitting on it cut the border in half.
      rect.bottom.should eq(body.bottom - Pet::BOTTOM_MARGIN)
      # The rows below and above her plate are untouched, and so is everything left of
      # the plate's padding.
      (rect.bottom..body.bottom).each { |y| backend.row(y).strip.should be_empty }
      backend.row(rect.y - 1).strip.should be_empty
      (Mascot::H).times do |i|
        backend.row(rect.y + i)[0, rect.x - 1].strip.should be_empty
      end
    end

    # The bug this reproduces: the gutter was sized for the SPRITE, but Pet.draw claims a
    # column of plate either side of it, so the right strip landed on the nested pane rule
    # and Repeater's Response pane lost its right border for her three rows. The outer
    # card's border one column further out survived, which is what made it read as a
    # rendering glitch rather than as occlusion.
    #
    # Driven by painting the rules FIRST and asserting they survive, rather than by pinning
    # the gutter to a number: the number is the thing that was wrong.
    it "leaves both stacked pane rules intact, on the right and at the bottom" do
      backend = MemoryBackend.new(80, 24)
      screen = Screen.new(backend)
      # A sub-tabbed tab's shape: the outer card's rule on the body edge, and a nested
      # Frame.card's one cell inside it. Discover, Sitemap and Repeater all draw this.
      [1, 2].each do |inset|
        (body.y...body.bottom).each { |y| screen.cell(body.right - inset, y, '│', Theme.text, Theme.bg) }
        (body.x...body.right).each { |x| screen.cell(x, body.bottom - inset, '─', Theme.text, Theme.bg) }
      end
      Pet.draw(screen, body, Mascot::Frame.new)
      rect = Pet.place(body).not_nil!
      Mascot::H.times do |i|
        row = backend.row(rect.y + i)
        row[body.right - 1].should eq('│') # the outer card's rule
        row[body.right - 2].should eq('│') # …and the nested pane's, the one she ate
      end
      [1, 2].each do |inset|
        rule = backend.row(body.bottom - inset)
        (rect.x - 1..rect.right).each { |x| rule[x].should eq('─') }
      end
    end

    # The only assertion that catches a width-2 glyph entering the sheet: such a glyph
    # claims x+1 as a continuation and orphan-clears the cell before it.
    it "never claims a continuation cell" do
      backend = MemoryBackend.new(80, 24)
      screen = Screen.new(backend)
      Mascot::POSES.each do |pose|
        Pet.draw(screen, body, Mascot::Frame.new(pose: pose, badge: '!'))
      end
      rect = Pet.place(body).not_nil!
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
        Pet.bubble_cap(Layout.compute(cols, 24).body.w)
      end
      caps.should eq(caps.sort)                         # never narrower on a wider terminal
      caps.first.should eq(Pet::BUBBLE_BASE_W)          # the narrow end keeps today's width
      caps.last.should eq(Pet::BUBBLE_MAX_W)            # …and a huge terminal stops at the ceiling
      Pet.bubble_cap(76).should be > Pet::BUBBLE_BASE_W # 80 cols, where she is actually read
    end

    # The fluid cap must not outgrow the narrow bodies the floor is above: at 40x24 the body
    # is 36, and BUBBLE_BASE_W alone would overhang it.
    it "keeps a wide bubble inside the body, floor included" do
      [40, 80, 120, 200].each do |cols|
        # NOT `body` — an `it` block closes over the describe-level local, and assigning to
        # it here would hand every later example a 200-column body on an 80x24 backend.
        wide = Layout.compute(cols, 24).body
        plate = Pet.place(wide).not_nil!
        box = Pet.bubble_box(wide, plate, "probe " * 60).not_nil!
        box.x.should be >= wide.x
        box.right.should be <= wide.right
        box.w.should be <= Pet.bubble_cap(wide.w)
      end
    end

    it "truncates a long bubble inside the body" do
      backend = MemoryBackend.new(80, 24)
      long = "probe " * 60
      Pet.draw(Screen.new(backend), body, Mascot::Frame.new(bubble: long))
      rect = Pet.place(body).not_nil!
      text_row = rect.y - Pet::BUBBLE_H + 1
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
      Pet::MIN_W.should be < floor.w
      rect = Pet.place(floor).not_nil!
      rect.w.should eq(Mascot::W)
      rect.right.should be <= floor.right - Pet::GUTTER
    end

    # Height is the live guard: body.h is height - 6 (or - 7 with the statusline).
    it "hides on a short terminal" do
      Pet.place(Layout.compute(120, 10).body).should be_nil
      Pet.place(Layout.compute(120, 24).body).should_not be_nil
    end

    it "paints nothing at all when the body is too small" do
      backend = MemoryBackend.new(80, 24)
      Pet.place(Rect.new(0, 0, Pet::MIN_W - 1, 10)).should be_nil
      Pet.draw(Screen.new(backend), Rect.new(0, 0, 20, 4), Mascot::Frame.new)
      backend.grid.each(&.all?(&.== ' ').should be_true)
    end
  end
end
