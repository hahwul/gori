require "../spec_helper"

private alias Tour = Gori::Tui::Tutorial

describe "Gori::Tui::Tutorial.first_session_steps" do
  it "starts at the screen the tour actually returns to" do
    Tour.first_session_steps(Tour::Handoff::Picker, 71)[0].should contain("New project")
    Tour.first_session_steps(Tour::Handoff::Direct, 71)[0].should contain("--db project")
    Tour.first_session_steps(Tour::Handoff::Direct, 71)[0].should contain("picker")
    Tour.first_session_steps(Tour::Handoff::Shell, 71)[0].should contain("Run gori")
    Tour.first_session_steps(Tour::Handoff::Session, 71)[0].should contain("Back in your session")
  end

  it "sends the user through the palette and names the CA verb" do
    Tour::Handoff.values.each do |handoff|
      steps = Tour.first_session_steps(handoff, 71)
      steps.size.should eq(6)
      steps[1].should contain("Open browser")
      steps[1].should_not contain("Project → Open browser")
      # "check CA" named no verb; the line now names the one the palette finds (#1380).
      steps[2].should contain(Gori::Verbs.registry["ca.export"].title)
      steps[3].should contain("capture is off")
      steps[3].should_not contain("History (3)")
      steps[4].should contain("Repeater")
    end
  end

  # Every key on the checklist is read from the registry, so a rebind is taught the way the
  # app now answers it — the literals it replaced were only ⌥-retagged (#1380).
  it "spells each key the way the registry reaches it" do
    registry = Gori::Verbs.registry
    [71, 33].each do |width|
      text = Tour.first_session_steps(Tour::Handoff::Shell, width, registry).join('\n')
      %w[browser.open ca.export capture.toggle history.repeater repeater.send tab.help help.tour].each do |id|
        text.should contain(Tour.reach(registry, id))
      end
    end
  end

  it "reaches a keyless verb through the palette, by its title" do
    registry = Gori::Verbs.registry
    Gori::Hotkeys.binding_for(registry, "browser.open").should be_nil
    pal = Gori::Hotkeys.binding_label(registry, "app.palette", "^P")
    Tour.reach(registry, "browser.open").should eq("#{pal} → #{registry["browser.open"].title}")
    Tour.reach(registry, "capture.toggle").should eq(Gori::Hotkeys.binding_label(registry, "capture.toggle", "?"))
  end

  it "keeps `i` off the Done cheat-sheet, where it would read as INS everywhere" do
    [36, 60, 71].each do |w|
      Tour.done_extra_lines(w)[0].should_not match(/\bi\b/)
    end
  end

  it "keeps each action visible at the minimum tutorial width" do
    # The Done card's interior is 36 columns at the 40-column terminal floor; its
    # numbered rows give 3 columns to the step number, leaving 33 for the action.
    Tour::Handoff.values.each do |handoff|
      Tour.first_session_steps(handoff, 33).each do |step|
        Gori::Tui::Screen.draw_width(step).should be <= 33, step
      end
    end
  end
end

describe "Gori::Tui::Tutorial minimum-width footer" do
  it "keeps the leave action and re-run command visible at 40 columns" do
    [Tour::Step::Welcome, Tour::Step::Done].each do |step|
      hint = Tour.compact_footer_hint(step)
      hint.should contain("esc esc leave")
      Gori::Tui::Screen.draw_width(hint).should be <= 40
    end
    rerun = Tour.done_extra_lines(36)[1]
    rerun.should contain("gori tutorial")
    Gori::Tui::Screen.draw_width(rerun).should be <= 36
    Gori::Tui::Screen.draw_width(Tour.done_extra_lines(71)[0]).should be <= 71
  end

  it "shortens the too-small message so its exit key survives the cut" do
    (10..120).each do |w|
      msg = Tour.too_small_message(w)
      Gori::Tui::Screen.draw_width(msg).should be <= {w, 3}.max
      msg.should contain("esc")
    end
    Tour.too_small_message(80).should contain("resize")
  end

  it "fits each lesson's compact hint, including overlay and insert states" do
    Tour::Step.values.each do |step|
      Gori::Tui::Screen.draw_width(Tour.compact_footer_hint(step)).should be <= 40
    end
    [{:palette, false, false}, {:space, false, false}, {:none, true, false}, {:none, false, true}].each do |(overlay, insert, armed)|
      hint = Tour.compact_footer_hint(Tour::Step::Practice, overlay, insert, armed)
      Gori::Tui::Screen.draw_width(hint).should be <= 40
    end
  end
end
