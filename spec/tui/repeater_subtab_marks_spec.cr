require "../spec_helper"
require "../support/fake_host"
require "file_utils"

include Gori::Tui

# `FakeHost#confirm` runs the action straight through and records {title, message}, so both
# halves of a batch close's contract are visible here: what the dialog SAID, and what then went.
private class MarksHost < FakeHost
  getter statuses = [] of String
  # With `defer` set, `confirm` HOLDS the action the way the real shell does — `Runner#confirm`
  # runs it from `on_close`, at least one event-loop turn later — so an example can put a peer
  # change between the dialog opening and the operator pressing ↵.
  property? defer = false
  getter pending : Proc(Nil)? = nil

  def status(message : String) : Nil
    @statuses << message
  end

  def confirm(title : String, message : String, *, confirm_label : String, danger : Bool,
              return_to : Symbol = :none, &action : -> Nil) : Nil
    @confirms << {title, message}
    @defer ? (@pending = action) : action.call
  end

  def press_enter : Nil
    if action = @pending
      @pending = nil
      action.call
    end
  end
end

private CA_ROOT = File.tempname("gori-marks-ca")
Spec.after_suite { FileUtils.rm_rf(CA_ROOT) }

private def shared_ca : Gori::Proxy::Tls::CertAuthority
  Gori::Proxy::Tls::CertAuthority.load_or_create(CA_ROOT)
end

# A project holding `names.size` saved repeater sessions, one per name, in that order.
private def with_repeaters(names : Array(String), &)
  root = File.tempname("gori-marks")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("marks")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    shared_ca, Gori::Verbs.registry, project)
  begin
    names.each_with_index do |name, i|
      req = "GET /#{name} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
      session.store.insert_repeater("http://127.0.0.1:9/", req.to_slice, false, true, nil, i)
    end
    host = MarksHost.new(session)
    yield RepeaterController.new(host), host, session.store
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# The request path is the one thing that tells the sessions apart.
private def paths(c : RepeaterController) : Array(String)
  (0...c.count).map { |i| c.view_at(i).not_nil!.request_text[/GET \/(\w+)/, 1] }
end

# Sub-tab multi-select on the Repeater strip (#683), driven against a real Store. `SubtabMarks`
# has its own spec; this one pins what the CONTROLLER does with it: the one target rule, the
# batch close, and the two things the identity key exists for.
describe "RepeaterController sub-tab marks" do
  it "targets the active chip until something is marked, then exactly the marks" do
    with_repeaters(%w[a b c d]) do |c, _, _|
      c.jump_subtab(1)
      c.target_subtab_indices.should eq([1])
      c.toggle_subtab_mark(0)
      c.toggle_subtab_mark(3)
      c.target_subtab_indices.should eq([0, 3]) # chip order, active chip NOT included
      c.subtab_mark_count.should eq(2)
      c.marked_chip_set.should eq(Set{0, 3})
    end
  end

  it "closes every marked sub-tab in one confirmed gesture and hands the marks back" do
    with_repeaters(%w[a b c d]) do |c, host, store|
      c.jump_subtab(1) # the active chip is NOT marked — it must survive
      c.toggle_subtab_mark(0)
      c.toggle_subtab_mark(3)
      c.request_close
      host.confirms.last[0].should eq("CLOSE REPEATERS")
      host.confirms.last[1].should start_with("Close 2 sub-tabs?")
      paths(c).should eq(%w[b c])
      store.repeaters_meta.size.should eq(2) # the rows went too
      c.subtab_mark_count.should eq(0)
      host.statuses.last.should eq("closed 2 sub-tabs")
      # The active chip followed the removal: `a` closing to its LEFT slid it from 1 to 0.
      c.subtab_index.should eq(0)
      c.view_at(0).not_nil!.request_text.should contain("GET /b")
    end
  end

  # `t` marks the chip and steps RIGHT, so after one press the mark and the cursor sit on
  # different chips — and that single mark used to be ignored: the batch arm gated on
  # `targets.size > 1`, so `^W` confirmed "Close repeater" for the UNMARKED chip under the
  # cursor while the strip said `1 marked`, and `space ▸ d` (which read `target_views`)
  # duplicated the marked one. One mark is a batch of one, on every gesture.
  it "acts on a single mark that is not the active chip, as the strip says it will" do
    with_repeaters(%w[a b c d]) do |c, host, _|
      c.jump_subtab(2)
      c.toggle_subtab_mark(2) # `t`: mark c…
      c.jump_subtab(3)        # …and step right, onto d
      c.request_close
      host.confirms.last[0].should eq("CLOSE REPEATERS")
      host.confirms.last[1].should start_with("Close 1 sub-tab?")
      paths(c).should eq(%w[a b d]) # c went, not d
      c.subtab_mark_count.should eq(0)
      host.statuses.last.should eq("closed 1 sub-tab")

      c.jump_subtab(0)
      c.toggle_subtab_mark(1)
      c.repeater_duplicate
      paths(c).should eq(%w[a b d b]) # the mark, not the cursor
    end
  end

  # The confirm's action runs a turn later, and the data_version poll has no modal guard: a
  # peer can reorder or delete a session while the dialog is up, and `reconcile` re-sorts the
  # strip. Indices captured before the dialog then name other sessions — which is why the
  # batch carries view objects and resolves them to chips only when it closes.
  it "resolves the marks AFTER the confirm, so a peer reorder behind the dialog cannot retarget it" do
    with_repeaters(%w[a b c d]) do |c, host, store|
      host.defer = true
      c.jump_subtab(0)
      c.toggle_subtab_mark(1) # b
      c.toggle_subtab_mark(3) # d
      c.request_close
      host.confirms.last[1].should start_with("Close 2 sub-tabs?")
      host.pending.should_not be_nil

      # Behind the dialog: the peer reverses the strip, and deletes `d` outright.
      ids = store.repeaters_meta.map(&.id)
      store.set_repeater_positions(ids.reverse)
      store.delete_repeater(ids[3])
      c.reconcile
      paths(c).should eq(%w[c b a])

      host.press_enter
      paths(c).should eq(%w[c a]) # b — the surviving mark — went; a and c were never marked
      c.subtab_mark_count.should eq(0)
      host.statuses.last.should eq("closed 1 sub-tab")
    end
  end

  it "closes just the active sub-tab when nothing is marked, as it always did" do
    with_repeaters(%w[a b c]) do |c, host, _|
      c.jump_subtab(2)
      c.request_close
      host.confirms.last[0].should eq("CLOSE REPEATER") # the single-tab dialog, word for word
      paths(c).should eq(%w[a b])
      host.statuses.last.should start_with("closed repeater (2 open)")
    end
  end

  it "keeps a mark on the view when a peer reorders the strip underneath it" do
    # The reason the mark set keys on identity: `reconcile` re-sorts by the saved position.
    # Mark `a` at chip 0, have the store reverse the order, reconcile — the mark must now sit
    # on the chip `a` MOVED to, not on whatever is at chip 0.
    with_repeaters(%w[a b c]) do |c, _, store|
      c.toggle_subtab_mark(0)
      ids = store.repeaters_meta.map(&.id)
      store.set_repeater_positions(ids.reverse)
      c.reconcile
      paths(c).should eq(%w[c b a])
      c.marked_subtab_indices.should eq([2])
    end
  end

  it "drops a mark whose sub-tab a peer deleted, so the count never names a gone session" do
    with_repeaters(%w[a b c]) do |c, _, store|
      c.toggle_subtab_mark(1)
      store.delete_repeater(store.repeaters_meta[1].id)
      c.reconcile
      paths(c).should eq(%w[a c])
      c.subtab_mark_count.should eq(0)
    end
  end

  it "duplicates marked sub-tabs onto the END of the strip, even after a close left a hole" do
    # Pins the position fix: a new row used to take `@repeaters.size` as its position, which
    # collides once a close leaves a gap, and `reconcile`'s {position, id} sort then dropped
    # the clone into the middle. With `next_repeater_position` the clones append and stay put.
    with_repeaters(%w[a b c d]) do |c, _, _|
      c.jump_subtab(1)
      c.request_close # close `b`, leaving positions {0, 2, 3}
      paths(c).should eq(%w[a c d])
      c.toggle_subtab_mark(0)
      c.toggle_subtab_mark(1)
      c.repeater_duplicate
      paths(c).should eq(%w[a c d a c])
      c.reconcile # the saved order must agree with what the strip shows
      paths(c).should eq(%w[a c d a c])
    end
  end
end
