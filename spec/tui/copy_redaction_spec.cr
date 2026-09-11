require "../spec_helper"

include Gori::Tui

# "Copy as…" under a redaction profile (#1035). The TUI has no per-copy flag — a keystroke has
# no analogue of `--redact` — so the whole question is whether this project redacts by DEFAULT,
# and these pin that the answer reaches every derived row of the menu, not just the Body one.
private def add_json_flow(store, *, request : String, response : String, target = "/login")
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "h.test", port: 443,
    method: "POST", target: target, http_version: "HTTP/1.1",
    head: "POST #{target} HTTP/1.1\r\nHost: h.test\r\nContent-Type: application/json\r\n\r\n".to_slice,
    body: request.to_slice, source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200,
    head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n".to_slice,
    body: response.to_slice, content_type: "application/json"))
  id
end

# The project's own "redact by default" switch, plus a pinned salt so the placeholders below
# are reproducible. `Redact.salt` is process-wide and `arm_redaction` would mint one into the
# suite's shared settings.json otherwise.
private def redacting(store, &)
  before = Gori::Redact.salt
  Gori::Redact.salt = "spec-salt"
  Gori::Redact::Policy.write_project_scope(store,
    Gori::Redact::Policy::ProjectScope.new(default: true))
  begin
    yield
  ensure
    Gori::Redact.salt = before
  end
end

describe "copy-as under a redaction profile" do
  it "leaves every row exactly as captured when nothing turns redaction on" do
    with_store do |store|
      id = add_json_flow(store, request: %({"password":"pw"}), response: %({"token":"t"}))
      view = HistoryView.new
      view.reload(store)
      title, opts = view.list_copy_as_menu(store, [id])
      title.should eq "COPY REQUEST AS"
      opts.to_h { |o| {o.key, o} }['b'].text.should eq %({"password":"pw"})
    end
  end

  it "sanitizes every row derived from the bytes, not only the Body one" do
    with_store do |store|
      id = add_json_flow(store, request: %({"user":"ada","password":"pw"}), response: %({"token":"t"}))
      redacting(store) do
        view = HistoryView.new
        view.reload(store)
        title, opts = view.list_copy_as_menu(store, [id])
        # The heading carries the count: the picker is the last thing seen before the clipboard.
        title.should eq "COPY REQUEST AS · SANITIZED (2)"
        by_key = opts.to_h { |o| {o.key, o} }
        placeholder = Gori::Redact.placeholder("pw")
        by_key['b'].text.should eq %({"user":"ada","password":"#{placeholder}"})
        by_key['r'].text.should contain placeholder # Raw request
        by_key['r'].text.should_not contain "\"pw\""
        by_key['l'].text.should contain placeholder                   # cURL
        by_key['y'].text.should contain placeholder                   # Python
        by_key['p'].text.should contain Gori::Redact.placeholder("t") # Req + Res pair
        # …and the head it rebuilt describes the body it is now carrying.
        by_key['h'].text.should contain "Content-Length: #{by_key['b'].text.bytesize}"
      end
    end
  end

  it "sanitizes the detail panes the same way" do
    with_store do |store|
      add_json_flow(store, request: %({"password":"pw"}), response: %({"token":"t"}))
      redacting(store) do
        view = HistoryView.new
        view.reload(store)
        view.open_detail(store).should be_true
        title, opts = view.detail_copy_as_menu(Gori::Redact::Policy.ambient(store))
        title.should eq "COPY REQUEST AS · SANITIZED (2)"
        opts.to_h { |o| {o.key, o} }['b'].text.should eq %({"password":"#{Gori::Redact.placeholder("pw")}"})
        view.toggle_pane
        rtitle, ropts = view.detail_copy_as_menu(Gori::Redact::Policy.ambient(store))
        rtitle.should eq "COPY RESPONSE AS · SANITIZED (2)"
        ropts.to_h { |o| {o.key, o} }['b'].text.should eq %({"token":"#{Gori::Redact.placeholder("t")}"})
      end
    end
  end

  it "totals the set-shaped rows across a mark set" do
    with_store do |store|
      a = add_json_flow(store, request: %({"password":"pw"}), response: %({"a":1}), target: "/a")
      b = add_json_flow(store, request: %({"password":"pw2"}), response: %({"b":2}), target: "/b")
      redacting(store) do
        view = HistoryView.new
        view.reload(store)
        title, opts = view.list_copy_as_menu(store, [a, b])
        title.should eq "COPY 2 FLOWS AS · SANITIZED (2)"
        raw = opts.to_h { |o| {o.key, o} }['r'].text
        raw.should_not contain "\"pw\""
        raw.should_not contain "\"pw2\""
        raw.should contain Gori::Redact.placeholder("pw")
        raw.should contain Gori::Redact.placeholder("pw2")
      end
    end
  end

  it "does not mark a URL-only set SANITIZED — nothing there went through a profile" do
    with_store do |store|
      # Past COPY_BYTES_CAP the menu carries URLs and hosts only, and no body is ever read.
      ids = (0...(HistoryView::COPY_BYTES_CAP + 1)).map do |i|
        add_json_flow(store, request: %({"password":"pw"}), response: %({"a":1}), target: "/#{i}")
      end
      redacting(store) do
        view = HistoryView.new
        view.reload(store)
        title, opts = view.list_copy_as_menu(store, ids)
        title.should eq "COPY #{ids.size} FLOWS AS"
        opts.map(&.key).should_not contain 'r'
      end
    end
  end

  it "leaves the stored flow untouched, so the next replay is byte-identical" do
    with_store do |store|
      id = add_json_flow(store, request: %({"password":"pw"}), response: %({"token":"t"}))
      redacting(store) do
        view = HistoryView.new
        view.reload(store)
        view.list_copy_as_menu(store, [id])
      end
      detail = store.get_flow(id).not_nil!
      String.new(detail.request_body.not_nil!).should eq %({"password":"pw"})
      String.new(detail.response_body.not_nil!).should eq %({"token":"t"})
    end
  end
end
