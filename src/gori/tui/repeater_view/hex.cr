# The `^X` hex editor over the REQUEST pane: entering/leaving it, and the nibble-level
# edits it takes while it is the authoritative buffer — reopens Gori::Tui::RepeaterView
# (see tui/repeater_view.cr for the class, its state and the layout it draws).
class Gori::Tui::RepeaterView
  # --- hex edit (^X on the REQUEST pane) ---
  # While @req_hex_edit is set, the byte buffer is AUTHORITATIVE (the TextArea is
  # frozen/stale) — every request consumer reads it. Lossiness lives only at the
  # text boundary (enter snapshot, exit write-back, persist), documented in-UI.
  def request_hex? : Bool
    !@req_hex_edit.nil?
  end

  def toggle_request_hex : Bool
    # A gRPC tab only exposes hex for a reframable (unary) payload; a 0-/multi-message
    # body has nothing to edit, so entering hex is a no-op (the controller also guards
    # this, but keep the view self-consistent for any caller).
    return false if @grpc_mode && !@grpc_reframable && !@req_hex_edit
    @req_hex_edit ? exit_request_hex : enter_request_hex
    request_hex?
  end

  private def enter_request_hex : Nil
    # In gRPC mode the hex buffer edits the deframed message PAYLOAD (the head stays in
    # @editor, sent as text); grpc_request_bytes re-length-prefixes it on send. Otherwise
    # it snapshots the whole wire request.
    #
    # `wire_bytes`, NOT `to_bytes`. `to_bytes` re-joins the LF projection with CRLF, so the
    # "raw bytes" pane was a FABRICATION: it invented an 0x0D in front of every bare LF in
    # the body and showed the operator bytes that had never existed anywhere. Worse, hex
    # mode deliberately disables auto-Content-Length, so those invented bytes shipped under
    # the head's older, shorter CL and the remainder was left on the socket for the origin
    # to read as the front of the next request — gori desyncing its own connection while
    # reporting `✓ sent`. Hex mode is the documented byte-exact escape hatch; it has to
    # start from the bytes.
    @req_hex_edit = HexEdit.new(@grpc_mode ? @grpc_payload : @editor.wire_bytes)
    @scroll_req = 0 # entering the same bytes isn't an edit — no @dirty
  end

  private def exit_request_hex : Nil
    if (h = @req_hex_edit) && h.mutated? # a pure peek (no edits) leaves state + @dirty untouched
      if @grpc_mode
        @grpc_payload = h.to_bytes # keep the edited payload byte-exact (reframed on send)
      else
        # Round-trips byte-exactly now: set_text keeps each line's terminator in @eols, and
        # `String.new(Bytes)` does not scrub, so the hex buffer's bytes come back out of
        # `wire_bytes` unchanged — hex ⇄ text is no longer a one-way door.
        @editor.set_text(String.new(h.to_bytes))
      end
      @dirty = true # the edit is a content change
    end
    @req_hex_edit = nil
  end

  # Mutators delegated from the Runner's hex key handler (each marks @dirty only on
  # a real change, so save persists + the cross-session reconcile won't clobber).
  def hex_set_nibble(c : Char) : Nil
    return unless (h = @req_hex_edit) && (v = c.to_i?(16))
    @dirty = true if h.set_nibble(v)
  end

  def hex_move(dr : Int32, dc : Int32) : Nil # navigation does NOT dirty
    return unless h = @req_hex_edit
    if dr != 0
      h.move_rows(dr)
    elsif dc < 0
      h.move_left
    elsif dc > 0
      h.move_right
    end
  end

  def hex_home : Nil
    @req_hex_edit.try(&.home)
  end

  def hex_end : Nil
    @req_hex_edit.try(&.end_of_row)
  end

  def hex_insert : Nil
    @dirty = true if @req_hex_edit.try(&.insert_byte)
  end

  def hex_backspace : Nil
    @dirty = true if @req_hex_edit.try(&.backspace)
  end

  def hex_delete : Nil
    @dirty = true if @req_hex_edit.try(&.delete)
  end
end
