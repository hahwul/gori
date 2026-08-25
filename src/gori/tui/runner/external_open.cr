require "../../external_open"

# "Open response in browser" — the two ExecContext verbs (History's stored flow, the
# Repeater's live result) plus the one spawn they share. Reopens Gori::Tui::Runner (see
# tui/runner.cr for the event loop, Host facade, overlays, and rendering).
#
# The module under `src/gori/external_open.cr` is pure: it decodes, names, writes and prunes.
# Everything that touches a PROCESS is here, which is the split `run_external_editor` already
# draws — except that this one does NOT suspend the terminal. `open` / `xdg-open` hand the path
# to the desktop and exit immediately; they read no stdin and paint no screen, so leaving the
# alt-screen for them would flash the terminal for nothing and cost a full repaint.
class Gori::Tui::Runner < Gori::Verb::ExecContext
  def open_response_external : Nil
    # `history_target_flow_id`, NOT the list cursor: `detail.open-browser` is a
    # HistoryDetail-scope verb, and live capture advances the cursor (`@selected = 0` on a new
    # flow) while the detail overlay stays pinned to its own. Reading the cursor here would
    # open the response of whatever just arrived instead of the one on screen — the exact
    # hazard that resolver exists for, and what every sibling detail verb goes through.
    id = history_target_flow_id
    return status("open in browser: select a flow first") unless id
    detail = @session.store.get_flow(id)
    return status("open in browser: flow ##{id} is no longer in History") unless detail
    # The head goes in as well as the body: it carries the `Content-Type` the suffix comes
    # from AND the `Content-Encoding` the body has to be inflated against.
    #
    # `response_body_truncated?` goes in too. The capture cap defaults to 2 MiB, so a stored
    # body over that size is a PREFIX, and every other surface says so (`gori history` prints
    # `[response body truncated]`, the MCP serializer and the HAR export both carry the flag).
    # Without it this verb opened the prefix and reported it as the document.
    preview("flow-#{id}", detail.response_head, detail.response_body, detail.response_body_truncated?)
  end

  def repeater_open_response_external : Nil
    v = repeater_controller.current_view
    return status("open in browser: no repeater tab open") unless v
    wire = v.response_wire
    return status("open in browser: send the request first — there is no response yet") unless wire
    head, body = wire
    # Named by the SUB-TAB index rather than a store id: a hand-authored tab has no row, and
    # the index is what the operator sees on the chip they invoked this from.
    preview("repeater-#{repeater_controller.current_idx + 1}", head, body)
  end

  # Write the preview and hand it to the desktop. Every refusal is a status line, never a
  # raise: this is a convenience verb and a missing `xdg-open` must not end the session.
  private def preview(stem : String, head : Bytes?, body : Bytes?, body_truncated : Bool = false) : Nil
    result = begin
      ExternalOpen.write(stem, head, body, body_truncated)
    rescue ex : Gori::Error
      return status("open in browser: #{ex.message}")
    end

    cmd = ExternalOpen.opener(result.path)
    unless cmd
      # No opener to call, but the file IS written — so say where it is rather than throwing
      # the work away. On a platform gori has no `open` for, a path the operator can paste
      # into their own viewer is the whole feature.
      return status("wrote #{result.path} — no desktop opener on this platform, open it yourself")
    end
    program, args = cmd

    begin
      # Waited on rather than detached, because the exit code is the only place the useful
      # refusal lives (`xdg-open` answers 3 for "no handler", 4 for "the action failed") and
      # both openers are dispatchers that return in milliseconds.
      #
      # All three streams CLOSED, and stdin most of all: on a Linux box with no desktop
      # session `xdg-open` walks its fallback list and can reach a TERMINAL browser, which
      # would take the alt-screen out from under the TUI. With no stdin it exits instead.
      st = Process.run(program, args,
        input: Process::Redirect::Close,
        output: Process::Redirect::Close,
        error: Process::Redirect::Close)
      unless st.success?
        return status("open in browser: #{program} exited #{st.exit_code} — the file is at #{result.path}")
      end
    rescue File::NotFoundError
      # `xdg-open` is absent on a bare box or a minimal container, and this is the ordinary
      # shape of that — not a bug to surface as one.
      return status("open in browser: #{program} is not installed — the file is at #{result.path}")
    rescue ex
      return status("open in browser: #{program} failed: #{ex.message} — the file is at #{result.path}")
    end

    status(opened_message(result))
  end

  # What the operator is told. It names the SIZE and the TYPE because those are the two things
  # that explain a viewer's behaviour ("why is it plain text" → the response said
  # `text/plain`), and it says "live" for a document a browser will EXECUTE, because the verb
  # is one keystroke and the page is the target's.
  private def opened_message(result : ExternalOpen::Result) : String
    kind = result.media || "unknown type"
    size = Fmt.size(result.bytes.to_i64)
    warn = ExternalOpen.executes?(result) ? " — scripts in it will RUN" : ""
    cut = result.truncated ? " (truncated)" : ""
    "opened #{File.basename(result.path)} · #{kind} · #{size}#{cut}#{warn}"
  end
end
