require "../spec_helper"
require "file_utils"

# `space ▸ m` (Mine parameters) and `space ▸ q` (Send to Sequencer) in the Repeater tab hand
# the editor's text to `build_seed_from_request`, whose first statement normalizes line
# endings. That normalization ran as a PCRE `gsub(/\r?\n/, "\r\n")`, and PCRE2 raises
# `ArgumentError` on a subject that is not valid UTF-8 — which a Repeater buffer routinely is,
# because `origin_form_text` seeds it from RAW CAPTURED BYTES (a multipart JPEG upload, a
# protobuf/gzip body, a Latin-1 header). The raise has no `rescue` before `Runner#run`, so the
# verb silently did nothing behind a generic "recovered from an internal error" toast, and the
# third press inside the 10s TICK_ERROR_WINDOW re-raised and ended the session.
#
# `SequencerController#sequence_from_text` — the Runner's `:sequencer` send-selection target,
# i.e. `space ▸ Q` over a band the operator highlighted in a read pane — is the THIRD site of the
# same class: it split the selection with `split(/\r?\n/)`, and a band selected in a pane
# rendering raw bytes carries them. One bug class, one file: splitting these examples across
# `miner_view_spec.cr` and `sequencer_view_spec.cr` would hide the class and duplicate the host
# double twice over.
#
# Same hazard, same buffer, already fixed twice elsewhere: `TextArea#searchable?` refuses ^F on
# it, `Fuzz::Template.mark_json` rescues the ArgumentError, `MCP::RequestBuilder.normalize_raw`
# walks bytes. These three seeds kept the naked regex.
#
# Driven through the PUBLIC entry points the Runner actually calls — `build_seed_from_request`
# and `sequence_from_text` — so the examples pin the shipped path rather than a re-implemented
# helper.

private class SeedBytesFakeHost
  include Gori::Tui::Host

  getter statuses = [] of String
  property active_tab : Symbol = :repeater

  def initialize(@session : Gori::Session)
    @jobs = Gori::Tui::Jobs.new
    @notifications = Gori::Tui::Notifications.new
  end

  def session : Gori::Session
    @session
  end

  def jobs : Gori::Tui::Jobs
    @jobs
  end

  def notifications : Gori::Tui::Notifications
    @notifications
  end

  def status(message : String) : Nil
    @statuses << message
  end

  def request_overlay(kind : Symbol) : Nil
  end

  def request_focus(pane : Symbol) : Nil
  end

  def focus_body : Nil
  end

  def switch_tab(tab : Symbol) : Nil
  end

  def goto_tab(tab : Symbol) : Nil
  end

  def open_palette : Nil
  end

  def open_help_query(surface : Symbol) : Nil
  end

  def open_space_menu : Nil
  end

  def open_fuzz_set_editor(edit_index : Int32?) : Nil
  end

  def open_fuzz_advanced_editor : Nil
  end

  def open_authorize_identities : Nil
  end

  def reconfigure_sequence : Nil
  end

  def open_scope_rule_editor(edit_id : Int64?, kind : String, match_type : String, pattern : String) : Nil
  end

  def open_custom_rule_editor(rule : Gori::Probe::CustomRule?) : Nil
  end

  def open_rewriter_rule_editor(rule : Gori::Store::MatchRule?) : Nil
  end

  def open_colormarker_rule_editor(rule : Gori::Store::ColorRule?) : Nil
  end

  def open_colormarker_color_editor(color : Gori::Settings::ColormarkerColor?) : Nil
  end

  def open_extract_rule_editor(rule : Gori::Store::ExtractRule?) : Nil
  end

  def open_chain_save : Nil
  end

  def open_chain_load : Nil
  end

  def open_oast_provider_editor(provider : Gori::Oast::ProviderConfig?) : Nil
  end

  def confirm(title : String, message : String, *, confirm_label : String, danger : Bool,
              return_to : Symbol = :none, &action : -> Nil) : Nil
    action.call
  end

  def overlay : Symbol
    :none
  end

  def focus : Symbol
    :body
  end

  def reveal? : Bool
    false
  end

  def toggle_reveal : Nil
  end

  def pretty? : Bool
    false
  end

  def toggle_pretty : Nil
  end

  def toggle_scope_lens : Nil
  end

  def toggle_sandbox : Nil
  end

  def apply_project_network(bind_host : String, bind_port : Int32, upstream : String,
                            connect_secs : Int32, io_secs : Int32, capture_mib : Int32) : String
    ""
  end
end

# The CA root keypair is the slow part of standing a Session up; no example asserts anything
# about it, so it is built once.
private SEED_BYTES_CA_ROOT = File.tempname("gori-seedbytes-ca")
Spec.after_suite { FileUtils.rm_rf(SEED_BYTES_CA_ROOT) }

private def with_seed_bytes_controllers(&)
  root = File.tempname("gori-seedbytes")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("seedbytes")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(SEED_BYTES_CA_ROOT), Gori::Verbs.registry, project)
  begin
    host = SeedBytesFakeHost.new(session)
    yield Gori::Tui::MinerController.new(host), Gori::Tui::SequencerController.new(host), host
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# A Repeater buffer as `space ▸ r` leaves it: a captured multipart upload whose part body is a
# JPEG (SOI + JFIF marker). Already CRLF throughout — the editor round-trips the capture's own
# terminators — so a correct normalization is the identity function here.
private def binary_repeater_buffer : String
  body = String.build do |io|
    io << "--b\r\nContent-Disposition: form-data; name=\"f\"; filename=\"a.jpg\"\r\n"
    io << "Content-Type: image/jpeg\r\n\r\n"
    io.write(Bytes[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00])
    io << "\r\n--b--\r\n"
  end
  "POST /upload?id=1 HTTP/1.1\r\nHost: h.test\r\n" \
  "Content-Type: multipart/form-data; boundary=b\r\n" \
  "Content-Length: #{body.bytesize}\r\n\r\n#{body}"
end

describe "Repeater → Mine / Sequencer seeding on a non-UTF-8 buffer" do
  it "mines a captured binary request instead of raising out of the run loop" do
    raw = binary_repeater_buffer
    raw.valid_encoding?.should be_false # guard the guard: the fixture IS the payload

    with_seed_bytes_controllers do |miner, _seq|
      seed = miner.build_seed_from_request("http://h.test", raw, false, nil)
      # P7: the operator's bytes go on the wire verbatim — byte-for-byte, not `contain`.
      seed.request.to_a.should eq(raw.to_slice.to_a)
      # …and no `.scrub` crept in as the "fix": the seed is still the invalid-UTF-8 payload.
      String.new(seed.request).valid_encoding?.should be_false
      seed.summary.should eq("POST /upload?id=1")
    end
  end

  it "sequences a captured binary request instead of raising out of the run loop" do
    raw = binary_repeater_buffer
    with_seed_bytes_controllers do |_miner, seq|
      seed = seq.build_seed_from_request("http://h.test", raw, false, nil)
      seed.request.to_a.should eq(raw.to_slice.to_a)
      String.new(seed.request).valid_encoding?.should be_false
    end
  end

  # The regex consumed only the trailing `\r\n` of `"a\r\r\n"`, leaving the first CR alone —
  # the pathological shape `TextArea#split_wire` exists to preserve. A byte walk that dropped
  # every CR before an LF would collapse it, trading a crash for a silently mangled request.
  it "keeps a doubled CR before an LF, exactly as the regex did" do
    raw = "POST /p HTTP/1.1\r\nHost: h.test\r\nContent-Length: 4\r\n\r\na\r\r\n"
    with_seed_bytes_controllers do |miner, seq|
      miner.build_seed_from_request("http://h.test", raw, false, nil).request.to_a.should eq(raw.to_slice.to_a)
      seq.build_seed_from_request("http://h.test", raw, false, nil).request.to_a.should eq(raw.to_slice.to_a)
    end
  end

  # …while a lone LF anywhere — head OR body — is still promoted, as the regex promoted it.
  it "still promotes a bare LF in the head and in the body" do
    raw = "POST /p HTTP/1.1\nHost: h.test\n\na\nb"
    want = "POST /p HTTP/1.1\r\nHost: h.test\r\n\r\na\r\nb"
    with_seed_bytes_controllers do |miner, seq|
      miner.build_seed_from_request("http://h.test", raw, false, nil).request.to_a.should eq(want.to_slice.to_a)
      seq.build_seed_from_request("http://h.test", raw, false, nil).request.to_a.should eq(want.to_slice.to_a)
    end
  end
end

# The third site of the same class, one call further out: `space ▸ Q` over a selected band goes
# to `SequencerController#sequence_from_text`, which split the payload into manual tokens with
# `split(/\r?\n/)` — the same PCRE raise, out of the same `Runner#run` with no rescue under it.
#
# Asserted on `config.manual_tokens` and the status line, WITHOUT draining the run: the `spawn`
# in `start_run` is the last statement and Crystal's single-threaded scheduler has not run that
# fiber yet when the call returns, so the config the split produced is readable with nothing
# else having happened. `view.load` binds the caller's LIVE `Config` instance (see the comment
# on `Sequencer::PlanOptions#config`), so this is the changed line's direct output. Abandoning
# the fiber is safe here and only here: manual mode is analyse-only — `Plan.analyse` gives it
# `origin: nil` / `backend: nil`, `run_manual` is pure, both channels are 256-buffered, and
# `persist_new` returns nil for manual ("tokens never persist"), so it touches no socket and no
# store. Draining instead would run `finish_job` → `v.report` over these same bytes, which is a
# different question than this file's.
describe "Gori::Tui::SequencerController#sequence_from_text on a non-UTF-8 selection" do
  # A band selected in a read pane showing raw captured bytes: session cookies whose value
  # carries a 0xFF the pane renders but PCRE2 refuses as a subject. The trailing blank line is
  # what a selection to end-of-band leaves behind, and both splits drop it.
  it "analyzes a selection of raw bytes instead of raising out of the run loop" do
    payload = String.build do |io|
      io << "sid="
      io.write(Bytes[0xFF, 0xD8, 0x41])
      io << "\r\nsid="
      io.write(Bytes[0xFF, 0xD8, 0x42])
      io << "\n  \r\n"
    end
    payload.valid_encoding?.should be_false # guard the guard: the fixture IS the payload
    want = [Bytes[0x73, 0x69, 0x64, 0x3D, 0xFF, 0xD8, 0x41].to_a,
            Bytes[0x73, 0x69, 0x64, 0x3D, 0xFF, 0xD8, 0x42].to_a]

    with_seed_bytes_controllers do |_miner, seq, host|
      seq.sequence_from_text(payload)
      seq.count.should eq(1)
      v = seq.current_view.not_nil!
      v.config.mode.manual?.should be_true
      # Byte-for-byte, not `contain`: the tokens are the operator's observed bytes and the
      # verdict is about their entropy, so a substituted U+FFFD would be a different token.
      v.config.manual_tokens.map(&.to_slice.to_a).should eq(want)
      # …and no `.scrub` crept in as the "fix".
      v.config.manual_tokens.first.valid_encoding?.should be_false
      host.statuses.last.should eq("sequencer ← 2 manual tokens")
    end
  end

  # Companion, not proof (it passes under the old regex too): pins the "byte-equivalent to the
  # regex" claim the source comment makes — `.strip` drops the CR the regex used to consume, and
  # an all-blank selection still takes the early return instead of opening a session.
  it "splits CRLF-delimited tokens exactly as the regex did, and refuses a blank selection" do
    with_seed_bytes_controllers do |_miner, seq, host|
      seq.sequence_from_text("a\r\nb\r\n")
      seq.current_view.not_nil!.config.manual_tokens.should eq(["a", "b"])

      seq.sequence_from_text("\r\n  \n\t\n")
      host.statuses.last.should eq("nothing to analyze")
      seq.count.should eq(1) # no second session opened
    end
  end
end
