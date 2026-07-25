require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"

include Gori::Tui

private def ckey(k : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, char: char)
end

# The "Import CA certificate" popup (palette → ca.import). It is a DUMB two-path form:
# the destructive half — validating the pair, dropping the card, and running the danger
# confirm before CertAuthority#import! — is the injected on_commit closure at the
# open-site (Runner#import_ca). These specs pin that split, because the failure mode of
# getting it wrong is a root CA replaced without a confirm.
describe Gori::Tui::CAImportOverlay do
  it "exposes the chrome the collapsed Runner ladders used to hard-code" do
    OverlayHarness.new(CAImportOverlay.new).assert_chrome(OverlayKind::CaImport, "IMPORT CA")
  end

  it "walks cert → key with ⇥/↓ and commits only from the LAST row" do
    ov = CAImportOverlay.new
    h = OverlayHarness.new(ov)
    h.on_commit { true }

    # A path under a directory that cannot exist, so the completion dropdown never opens
    # and ↵ means "next row" rather than "accept a suggestion" (it owns both).
    h.type("/gori-spec-no-such-dir/ca.pem").should eq(:open)
    # ↵ on the certificate row advances instead of submitting — a half-filled form must
    # not reach the confirm.
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.commits.should eq(0)
    h.type("/gori-spec-no-such-dir/ca.key").should eq(:open)
    h.press(Termisu::Input::Key::Enter).should eq(:closed)

    h.commits.should eq(1)
    ov.cert_path.should eq("/gori-spec-no-such-dir/ca.pem")
    ov.key_path.should eq("/gori-spec-no-such-dir/ca.key")
  end

  it "keeps the form up when the commit closure rejects it (a missing path)" do
    # Runner#submit_ca_import toasts "both … are required" and returns false; the card
    # must stay so the user can fill the row in, not vanish with the typed path.
    ov = CAImportOverlay.new
    h = OverlayHarness.new(ov, commit: false)
    h.press(Termisu::Input::Key::Down) # → key row
    h.press(Termisu::Input::Key::Enter).should eq(:open)
    h.commits.should eq(1) # it ran — it just refused to close
  end

  it "esc cancels and a click-away dismisses — neither ever commits" do
    h = OverlayHarness.new(CAImportOverlay.new)
    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    h.commits.should eq(0)

    away = OverlayHarness.new(CAImportOverlay.new)
    # Assert the RAW outcome too: the harness folds :cancel and a truthy :commit into
    # :closed, so eq(:closed) alone would still pass if clicking away started a CA swap.
    away.overlay.handle_click(away.area, 0, 0).should eq(:cancel)
    away.click(0, 0).should eq(:closed)
    away.commits.should eq(0)
  end

  it "click selects the field row under the pointer (rows start at box.y + 3)" do
    ov = CAImportOverlay.new
    h = OverlayHarness.new(ov)
    h.click_in_box(3, 4).should eq(:open) # the Private key row
    h.type("/gori-spec-no-such-dir/ca.key")
    ov.key_path.should eq("/gori-spec-no-such-dir/ca.key")
    ov.cert_path.should be_empty
  end

  it "scrolls the field cursor with the wheel" do
    ov = CAImportOverlay.new
    OverlayHarness.new(ov).wheel(3) # clamps at the last row
    ov.as(Overlay).handle_key(ckey(Termisu::Input::Key::Enter)).should eq(:commit)
  end

  it "routes IME preedit to the focused row" do
    h = OverlayHarness.new(CAImportOverlay.new)
    h.preedit("preedithere")
    h.rendered?("preedithere").should be_true
  end

  it "dismisses — never submits — when the window is too small to draw the card" do
    # The harness's DEFAULT_AREA is the whole screen, so this path is unreachable through
    # it; production hands `layout.body`, which is 6 rows shorter. With no box, every click
    # is a dismiss (the pre-migration `close_ca_import if box.nil?`), and the card degrades
    # to a one-line "needs a larger window" notice rather than a phantom form.
    tiny = Gori::Tui::Rect.new(2, 4, 30, 6)
    h = OverlayHarness.new(CAImportOverlay.new, area: tiny)
    h.box.should be_nil
    h.overlay.handle_click(tiny, 10, 5).should eq(:cancel) # raw: not a CA swap
    h.click(10, 5).should eq(:closed)
    h.commits.should eq(0)
    h.render.contains?("CA import needs a larger").should be_true # the rest is clipped by the 30-col area
  end

  it "keeps Tab path completion inside the overlay, caret at the end" do
    # Tab is the completion key here, NOT a field-advance the shell could claim: the
    # dropdown owns it while open. Driven end-to-end so the whole accept path stays covered.
    dir = File.join(Dir.tempdir, "gori-ca-import-spec-#{Process.pid}")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "root.pem"), "-----BEGIN CERTIFICATE-----")
    begin
      ov = CAImportOverlay.new
      h = OverlayHarness.new(ov)
      h.type("#{dir}/")                 # opens the dropdown on root.pem
      h.press(Termisu::Input::Key::Tab) # accept the completion
      ov.cert_path.should eq(File.join(dir, "root.pem"))
      h.type("X") # …and the caret is at the END
      ov.cert_path.should eq(File.join(dir, "root.pemX"))
      h.commits.should eq(0) # completing is not committing
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
