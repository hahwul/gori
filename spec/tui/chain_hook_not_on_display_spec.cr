require "../spec_helper"

include Gori::Tui

# A `§value¦chain§` step can be an `exec:` since #818 — the operator's own command, run with
# their privileges and allowed, by definition, to have side effects. A surface that REPLAYS such
# a chain to DRAW something therefore withholds it: drawing is not a send, and neither is
# restoring a tab that was saved with one in it.
#
# The counts are the assertion, and each example pins its own number rather than "few" — the
# defects these cover were 1-per-frame, 1-per-keystroke, 2-per-send and 1-per-row-selection, and
# only a count tells those apart from correct behaviour. `Rules#transform_message` makes the same
# argument for the Rewriter's OUTPUT pane (`run_hooks: false`, and the pane says so); these are
# the Decoder-chain half of it, which that seam left open.
#
# NOT covered here, deliberately: the Decoder tab's own chain field, which is live by design —
# it is the workbench `exec:` was built for. See `docs/content/guide/scripting.md`.

# A hook that appends one line per run and passes stdin through, plus a reader for the tally.
private def with_counting_hook(&)
  dir = File.tempname("gori-chain-hook")
  Dir.mkdir_p(dir)
  path = File.join(dir, "h.sh")
  tally = File.join(dir, "tally")
  File.write(path, "#!/bin/sh\necho ran >> '#{tally}'\ncat\n")
  File.chmod(path, 0o755)
  begin
    yield({path, -> { File.exists?(tally) ? File.read(tally).lines.size : 0 }})
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe "an exec: chain on a display path" do
  # Reopening a project restores every saved Repeater tab, and `restore` reflects
  # Content-Length; the reflection then ran on every subsequent keystroke. Both replayed the
  # marker's chain, so a saved tab holding `§v¦exec:…§` ran the operator's command at startup
  # and once per typed character after it.
  it "is not run by restoring a Repeater tab, nor by typing in it" do
    with_counting_hook do |hook, runs|
      view = RepeaterView.new
      view.restore("https://h.test",
        "POST /x HTTP/1.1\r\nHost: h.test\r\nContent-Length: 5\r\n\r\n§abc¦exec:#{hook}§",
        false, true)
      runs.call.should eq 0

      view.focus_pane(:request)
      5.times { view.edit_insert('x') }
      runs.call.should eq 0
    end
  end

  # …and the complement, which is the whole point of withholding it on the other paths: the
  # SEND still runs it, exactly once. It used to run twice — `refuse_bad_chains` executed the
  # chain to validate it and `render_marked` executed it again to build the bytes, so a
  # side-effecting hook fired twice and the verdict was about a different invocation than the
  # one whose output shipped.
  it "IS run by the send, exactly once" do
    with_counting_hook do |hook, runs|
      view = RepeaterView.new
      view.restore("https://h.test",
        "POST /x HTTP/1.1\r\nHost: h.test\r\nContent-Length: 5\r\n\r\n§abc¦exec:#{hook}§",
        false, true)
      String.new(view.request_bytes).should end_with("abc")
      runs.call.should eq 1
    end
  end

  # The visible Content-Length stops tracking the body for such a tab (the length is not
  # knowable without running the hook, and a number measured on the UNTRANSFORMED value is one
  # no request will carry). `^R` still frames correctly through `finalize_wire` — but `^L`
  # turning Auto-CL OFF hands the header to the operator, and `finalize_wire` stops resyncing,
  # so that gesture is the last moment gori can make the number true. It spends exactly one run.
  it "refreshes the header once when Auto-CL is switched off, and only then" do
    dir = File.tempname("gori-cl-hook")
    Dir.mkdir_p(dir)
    hook = File.join(dir, "h.sh")
    tally = File.join(dir, "tally")
    # Length-CHANGING, so a stale header is visible as the wrong number, not just a stale one.
    File.write(hook, "#!/bin/sh\necho ran >> '#{tally}'\ncat\nprintf XY\n")
    File.chmod(hook, 0o755)
    runs = -> { File.exists?(tally) ? File.read(tally).lines.size : 0 }
    begin
      view = RepeaterView.new
      view.restore("https://h.test",
        "POST /x HTTP/1.1\r\nHost: h.test\r\nContent-Length: 99\r\n\r\n§abc¦exec:#{hook}§",
        false, true)
      view.focus_pane(:request)
      view.edit_buffer_end
      view.edit_insert('x') # a BODY edit that would normally re-derive the header
      runs.call.should eq 0
      view.request_text.should contain("Content-Length: 99") # declined, not guessed

      view.toggle_auto_content_length.should be_false
      runs.call.should eq 1
      # The body renders as `abc` through the hook (`abcXY`) plus the typed `x` — six bytes,
      # and the header the operator now owns says exactly that.
      view.request_text.should contain("Content-Length: 6")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  # A Fuzzer row whose request the retention policy dropped is re-rendered from the template
  # every time it is selected. The engine already ran the hook on the send this row records;
  # redrawing the row must not fire it again for a request that is over.
  #
  # A DELTA, not an absolute: `build_engine` legitimately renders the baseline a few times at
  # plan time (`GrpcVerdict.framed_template?`, `Plan#rewrites_content_length?`,
  # `Outbound.request_target`), which is inside a run the operator started. What is asserted
  # here is that REDRAWING adds nothing to it.
  it "is not run by re-rendering a dropped Fuzzer row" do
    with_counting_hook do |hook, runs|
      path = File.tempname("gori-fuzzhook", ".db")
      store = Gori::Store.open(path)
      begin
        view = FuzzerView.new
        view.load_request("http://127.0.0.1:1/",
          "POST /x HTTP/1.1\r\nHost: h\r\ncontent-length: 3\r\n\r\n§abc¦exec:#{hook}§", false, "")
        view.apply_set(nil, Gori::Tui::SetSpec.new(:list, "abcdef"))
        _engine, err = view.build_engine(false, Gori::Scope.load(store), nil)
        err.should be_nil
        view.begin_run(1_i64)
        # keep_bodies dropped this row's request — the shape that reaches the reconstruction.
        view.append_result(Gori::Fuzz::Result.new(
          0_i64, ["abcdef"], nil, 404, 12_i64, 2, 1, 1000_i64, nil, false, false, nil))

        before = runs.call
        3.times { view.result_request(view.selected_result.not_nil!) }
        (runs.call - before).should eq 0

        # …and it SAYS so. Withholding silently would be worse than forking: the pane would
        # show the payload before the hook, with a Content-Length computed to match it, and
        # `Send to Repeater` / the Comparer slot would carry those bytes on with no caveat.
        # `Result#chain_error` cannot cover this — on the wire the hook ran fine.
        r = view.selected_result.not_nil!
        view.result_request(r).chain_withheld.should be_true
        view.result_request_note(r).not_nil!.should contain("was NOT re-run")
      ensure
        store.close
        File.delete?(path)
        File.delete?("#{path}-wal")
        File.delete?("#{path}-shm")
      end
    end
  end

  # `DecoderController` owns a live Host and cannot be stood up here, so the two restore-path
  # call sites are pinned by reading the source with comments stripped — the same technique
  # `agents_chip_spec.cr` uses, and for the same reason: the rule lives in the wiring.
  it "does not fork on a project open or a library edit (Decoder sub-tabs)" do
    src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "controllers",
      "decoder_controller.cr")).lines.reject(&.lstrip.starts_with?('#'))
    # `make_session` rebuilds every persisted sub-tab when a project opens.
    src.any?(&.includes?("Decoder.run(registry, input.text.to_slice, chain, run_hooks: false)"))
      .should be_true
    # `library_changed` re-derives EVERY open conversation on one ^S/^X.
    src.any?(&.includes?("Decoder.run(registry, s.input.text.to_slice, s.chain, run_hooks: false)"))
      .should be_true
  end
end
