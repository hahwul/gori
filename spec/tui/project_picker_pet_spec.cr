require "../spec_helper"

include Gori::Tui

# Miss Ring's stand on the PROJECT PICKER (ProjectPicker.pet_place). The picker paints her
# last, over the starfield and the card, so placement is the whole contract: anything she
# is allowed to occupy, she occupies opaquely. These sweep the rule over terminal sizes
# rather than a couple of hand-picked ones — the picker card is centred and its height
# tracks the brand block, so the sizes where she stops fitting are not obvious by eye.
describe Gori::Tui::ProjectPicker do
  # The two footer rows: h-2 is the hint, h-3 is the notice row her line rides. Landing on
  # either would put a mascot on top of the text she is meant to be speaking.
  it "keeps clear of the footer rows at every size she appears at" do
    (20..60).each do |h|
      (60..200).each do |w|
        next unless rect = ProjectPicker.pet_place(w, h)
        rect.bottom.should be <= h - 3
      end
    end
  end

  # The SPRITE may not touch the card — she stands there for the whole screen, and the
  # project list is what the operator is reading. (Her bubble is another matter: it floats
  # over the card for the few seconds she is talking, exactly as it does over a tab body in
  # the session. What it may not do is leave the terminal — see below.)
  it "never overlaps the picker card" do
    (20..60).each do |h|
      (60..200).each do |w|
        next unless rect = ProjectPicker.pet_place(w, h)
        box, _ = ProjectPicker.card_metrics(w, h)
        # Her plate claims a column either side of the sprite (Pet.draw), so the box that
        # actually gets painted is one wider on each side than `rect`.
        cols = (rect.x - 1) < box.right && (rect.right + 1) > box.x
        rows = rect.y < box.bottom && rect.bottom > box.y
        (cols && rows).should be_false
      end
    end
  end

  it "stays inside the terminal" do
    (20..60).each do |h|
      (60..200).each do |w|
        next unless rect = ProjectPicker.pet_place(w, h)
        (rect.x - 1).should be >= 0
        (rect.right + 1).should be <= w
        rect.y.should be >= 0
      end
    end
  end

  # The bargain `art_shown?` makes for the brand block: rather than shove the card aside or
  # paint over it, she simply doesn't appear when the terminal can't seat her beside it.
  # 80 columns is the floor that matters — the conventional terminal has room for her.
  it "seats her beside the card on a conventional terminal, and drops her on a narrow one" do
    ProjectPicker.pet_place(80, 24).should_not be_nil
    ProjectPicker.pet_place(120, 40).should_not be_nil
    ProjectPicker.pet_place(60, 24).should be_nil
    ProjectPicker.pet_place(40, 12).should be_nil
  end

  # The bubble is allowed over the card, so the card can't bound it — the terminal has to.
  # Swept with a line longer than any she actually says, which is what pushes it left and
  # up into whatever it is going to hit.
  it "keeps her bubble on screen and off the footer, however long the line" do
    long = "heads up: v10.20.30 is out · run: gori update" * 3
    (20..60).each do |h|
      (60..200).each do |w|
        next unless rect = ProjectPicker.pet_place(w, h)
        stage = ProjectPicker.pet_stage(w, h)
        next unless box = Pet.bubble_box(stage, rect, long)
        box.x.should be >= 0
        box.right.should be <= w
        box.y.should be >= 0
        box.bottom.should be <= rect.y # above her cap, so it can never reach the footer
      end
    end
  end

  # `pet_place` measures from `pet_stage` and the picker hands that SAME rect to Pet.draw,
  # so what these specs assert is what gets painted. Guards the pair from drifting apart.
  it "places from the stage the picker actually draws her on" do
    [{80, 24}, {120, 40}, {200, 60}].each do |(w, h)|
      next unless rect = ProjectPicker.pet_place(w, h)
      Pet.place(ProjectPicker.pet_stage(w, h)).should eq(rect)
    end
  end
end
