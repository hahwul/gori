require "../spec_helper"
require "file_utils"
require "base64"

include Gori::Tui

# What the ⌕ affordance opens has to be worth opening. `TabController#subtab_search_rows`
# builds the picker's rows, and two things about it are load-bearing:
#
#   * The DETAIL column is the same projection the `/` filter bar matches on
#     (`filter_subjects`). Before that, only Repeater filled it — on the other seven tabs a
#     session could be found by its chip label alone, which is exactly what an operator does
#     not remember once twenty of them have piled up. One description of a session, not two
#     that can disagree.
#   * The LABEL has its leading `N:` stripped, because `SubtabPicker#draw_row` already paints
#     the index in a column of its own. Together they read `3   3:login`.
#
# Driven through real controllers rather than a stub subclass: the chip-label format that the
# `N:` rule depends on lives in each controller, so a spec that invented its own labels would
# pass while the real ones regressed.

private class FakeHost
  include Gori::Tui::Host

  getter statuses = [] of String

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

  def active_tab : Symbol
    :jwt
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

private SEARCH_ROWS_CA = File.tempname("gori-search-rows-ca")
Spec.after_suite { FileUtils.rm_rf(SEARCH_ROWS_CA) }

# A real Session with one seeded Repeater tab, plus the Decoder controller over the same
# session (it opens with a default conversion of its own).
private def with_session(&)
  root = File.tempname("gori-search-rows")
  session = nil
  begin
    Dir.mkdir_p(root)
    project = Gori::ProjectRegistry.new(root).temp("searchrows")
    session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
      Gori::Proxy::Tls::CertAuthority.load_or_create(SEARCH_ROWS_CA), Gori::Verbs.registry, project)
    session.store.insert_repeater("https://shop.example.com/cart",
      "POST /cart/checkout HTTP/1.1\r\nHost: shop.example.com\r\nX-Api-Token: tok-sekret-9\r\n\r\n".to_slice, false, true, nil, 0)
    yield FakeHost.new(session)
  ensure
    session.try(&.close)
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

describe "TabController#subtab_search_rows" do
  it "strips the chip's N: index, which the picker draws in its own column" do
    with_session do |host|
      # Decoder takes the BASE implementation — the one that used to hand the picker a label
      # already carrying the number.
      rows = DecoderController.new(host).subtab_search_rows
      rows.should_not be_empty
      labels = DecoderController.new(host).subtab_labels
      labels.first.should match(/\A\d+:/) # the chip really is numbered ...
      rows.each(&.label.should_not(match(/\A\d+:/)))
    end
  end

  it "fills the detail column from the same projection the / filter matches on" do
    with_session do |host|
      row = RepeaterController.new(host).subtab_search_rows.first
      # Findable by host and by request line, not just by whatever the chip is named.
      row.detail.should contain("shop.example.com")
      row.detail.should contain("/cart/checkout")
      row.label.should_not contain("shop.example.com") # the label stays the session's name
    end
  end

  it "caps the detail so a long note body cannot become the haystack" do
    with_session do |host|
      RepeaterController.new(host).subtab_search_rows.each do |row|
        row.detail.size.should be <= Gori::Tui::TabController::SEARCH_DETAIL_MAX
      end
    end
  end

  it "carries the request content in the searchable extra, capped and off the drawn columns" do
    with_session do |host|
      row = RepeaterController.new(host).subtab_search_rows.first
      # A header lives only in the wire text — summary/target never show it, so before the
      # extra the one session sending this token was unfindable by it.
      row.extra.should contain("X-Api-Token: tok-sekret-9")
      row.detail.should_not contain("tok-sekret-9")
      row.extra.size.should be <= Gori::Tui::TabController::SEARCH_EXTRA_MAX

      # An empty session contributes no searchable text (a fresh Decoder conversion).
      DecoderController.new(host).subtab_search_rows.each(&.extra.strip.should(be_empty))
    end
  end

  it "fills the fuzzer's extra from its template" do
    with_session do |host|
      fc = FuzzerController.new(host)
      fc.fuzz_new
      # load_blank seeds "GET / HTTP/1.1\r\nHost: example.com..." — findable by a header
      # the summary (request line only) never shows.
      fc.subtab_search_rows.first.extra.should contain("Host: example.com")
    end
  end

  it "searches the WHOLE note body, past the 200-column detail cap" do
    with_session do |host|
      nc = NotesController.new(host)
      body = "title line\n" + ("filler word " * 40) + "BURIEDWORD tail"
      body.size.should be > Gori::Tui::TabController::SEARCH_DETAIL_MAX # the word is past detail's reach
      nc.view.replace_current(body)
      row = nc.subtab_search_rows.first
      row.detail.should_not contain("BURIEDWORD") # the drawn column stops at 200
      row.extra.should contain("BURIEDWORD")      # the picker still finds it
    end
  end

  it "searches the decoder's input and its decoded output" do
    with_session do |host|
      dc = DecoderController.new(host)
      dc.decoder_from_text("aGVsbG8td29ybGQ") # base64 of "hello-world", no chain yet
      row = dc.subtab_search_rows.last
      row.extra.should contain("aGVsbG8td29ybGQ") # the pasted input
    end
  end

  it "searches the JWT's decoded header and payload, not its opaque token" do
    with_session do |host|
      jc = JwtController.new(host)
      header = Base64.urlsafe_encode(%({"alg":"HS256","typ":"JWT"}), padding: false)
      payload = Base64.urlsafe_encode(%({"role":"admin","iss":"gori-test"}), padding: false)
      jc.jwt_from_text("#{header}.#{payload}.sig")
      extra = jc.subtab_search_rows.last.extra
      extra.should contain("admin")     # a claim the operator remembers ...
      extra.should contain("gori-test") # ... found in the DECODED payload
    end
  end
end
