require "../spec_helper"

# The VIEW half of `Repeater::PlanOptions#evidence_literals`: which names a seeded tab hands
# the send seam as the capture's own.
#
# Derived from the SEED bytes and re-derived when the grammar moves under them, for the reason
# `evidence_env_names` is (`adopt_evidence_env_seed`): a set computed under one grammar answers
# the wrong question under the other, and being one grammar behind here means either sending a
# capture's token as a live value or sending the operator's token as 15 literal bytes.
#
# `Env.literal_keys` and not a second derivation, because this is the same set the EDITOR is
# handed for painting and completion — what the pane greys out as literal has to be what the
# socket gets literally.

private def flow(request : String) : Gori::Store::FlowDetail
  row = Gori::Store::FlowRow.new(11_i64, 1_i64, "https", "GET", "h.test", 443, "/a",
    200, 100_i64, Gori::Store::FlowState::Complete, 50_i64, 1_i64, "text/html")
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", request.to_slice, nil,
    "HTTP/1.1 200 OK\r\n\r\n".to_slice, nil)
end

private def seeded(request : String) : Gori::Tui::RepeaterView
  view = Gori::Tui::RepeaterView.new
  view.load(flow(request))
  view
end

describe "Gori::Tui::RepeaterView#evidence_send_literals" do
  it "holds the tokens the capture arrived with, qualified under the namespaced grammar" do
    with_env_syntax(Gori::Env::Syntax::Namespaced) do
      view = seeded("GET /a?q=$BIND.TOKEN HTTP/1.1\r\nHost: h.test\r\n\r\n")
      view.evidence?.should be_true
      view.evidence_send_literals.should contain("BIND.TOKEN")
      # A token the operator types AFTERWARDS is theirs: the set is the SEED's, not the buffer's.
      view.evidence_send_literals.should_not contain("GEN.RANDOM_HEX")
    end
  end

  # The commonest shape by far, and the one the reported send hit: nothing in the capture is a
  # token under this grammar, so the seam resolves everything the operator typed.
  it "is empty for a capture that mentions no token" do
    with_env_syntax(Gori::Env::Syntax::Namespaced) do
      seeded("GET /api?$filter=x HTTP/1.1\r\nHost: h.test\r\n\r\n")
        .evidence_send_literals.should be_empty
    end
  end

  # …and the same capture under the bare grammar, where `$filter` IS a reference and the set
  # has to hold it or the send seam substitutes into a byte the origin sent.
  it "holds the bare name when the grammar makes it a reference" do
    with_env_syntax(Gori::Env::Syntax::Bare) do
      seeded("GET /api?$filter=x HTTP/1.1\r\nHost: h.test\r\n\r\n")
        .evidence_send_literals.should contain("filter")
    end
  end

  # A mid-session `env.syntax` flip (Project tab `s`) moves the question, so the answer has to
  # move with it — off the SEED bytes, which is why they are what the view keeps.
  it "re-derives when the grammar flips under it" do
    view = nil.as(Gori::Tui::RepeaterView?)
    with_env_syntax(Gori::Env::Syntax::Namespaced) do
      view = seeded("GET /api?$filter=x&q=$BIND.TOKEN HTTP/1.1\r\nHost: h.test\r\n\r\n")
      view.not_nil!.evidence_send_literals.should contain("BIND.TOKEN")
    end
    with_env_syntax(Gori::Env::Syntax::Bare) do
      Gori::Env.bump_highlight_rev
      names = view.not_nil!.evidence_send_literals
      names.should contain("filter")
      names.should_not contain("BIND.TOKEN")
    end
  end

  # A DRAFT has no capture, so it hands over nothing — and the controller passes nil rather
  # than this set for one (`repeater_plan`), because a draft's send pass was never narrowed.
  it "is empty on a hand-authored tab" do
    with_env_syntax(Gori::Env::Syntax::Namespaced) do
      view = Gori::Tui::RepeaterView.new
      view.load_blank
      view.evidence?.should be_false
      view.evidence_send_literals.should be_empty
    end
  end
end
