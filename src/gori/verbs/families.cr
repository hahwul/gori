require "../verb"

module Gori
  module Verbs
    # The space menu's verb families (#1274 WP9, `Verb::Family`). A verb joins one by naming a
    # member intent; the letter table here is the only place its level-2 letter is spelled.
    #
    # "Send flow to…" (`>`) holds the cross-tool sends of the selected flow(s). Send to
    # Repeater is `pinned:` on every tab that has it, so it keeps its level-1 letter (`r`, or
    # `R` where `r` runs the tab) and `space > r` also reaches it everywhere. Active scan and
    # Mock stay direct rows: one scans and one creates a rule, neither hands the flow on.
    SEND_FLOW = Verb::Family.new(:send_flow, "Send flow to…", '>', :send, [
      {:to_repeater, Verb::TOOL_LETTERS[:repeater]},
      {:to_fuzzer, Verb::TOOL_LETTERS[:fuzzer]},
      {:to_comparer, Verb::TOOL_LETTERS[:comparer]},
      {:to_miner, Verb::TOOL_LETTERS[:miner]},
      {:to_sequencer, Verb::TOOL_LETTERS[:sequencer]},
      {:to_authorize, Verb::TOOL_LETTERS[:authorize]},
      {:to_discover, Verb::TOOL_LETTERS[:discover]},
      {:to_browser, Verb::TOOL_LETTERS[:browser]},
    ])

    # "Display…" (`Z`) holds the toggles that change how a pane DRAWS what it holds — never a
    # write-back like pretty-print-request, which changes the request itself. Sticky: after a
    # flip the card comes back at the same row, whose `●`/`○` says what the pane now shows.
    # `a` shows every row a default lens leaves out — Probe's closed issues, the Params tab's
    # standard headers — the letter both tabs already answer bare (#1295).
    # Not `V`: under the vim keyset ⇧V selects a line in every read pane this row is drawn in,
    # so a dropped space would select instead of opening the card. `z` is vim's view-and-fold
    # prefix, and the capital keeps the lower case for single rows.
    # One intent reads one letter everywhere, so hex is `x` in the History detail and in both
    # Repeater panes (it was `e`, `x` and `h`). The Fuzzer's sort is a direct row: it is the
    # key a results triage presses most.
    DISPLAY = Verb::Family.new(:display, "Display…", 'Z', :view, [
      {:hex, 'x'},
      {:pretty, 'p'},
      {:unicode, 'u'},
      {:whitespace, 'b'},
      {:diff, 'd'},
      {:envelope, 'e'},
      {:static_assets, 's'},
      {:follow, 'f'},
      {:columns, 'c'},
      {:fold_ids, 'g'},
      {:fold_queries, 'q'},
      {:js_refs, 'J'},
      {:matched_only, 'm'},
      {:distribution, 'v'},
      {:compare_pane, 't'},
      {:fold_unchanged, 'z'},
      {:show_all, 'a'},
    ], sticky: true)

    # "Protocol…" (`P`) holds the per-request transport settings of the Repeater and the
    # Fuzzer: what goes on the wire, not what the pane draws. Sticky, for the same reason as
    # Display…, and because smuggling and TLS work flips two or three of them together. The
    # TLS fingerprint row shows its preset's name rather than `●`.
    PROTOCOL = Verb::Family.new(:protocol, "Protocol…", 'P', :none, [
      {:http2, '2'},
      {:sni, 's'},
      {:auto_content_length, 'c'},
      {:ws_key, 'w'},
      {:grpc_reframe, 'r'},
      {:grpc_fields, 'f'},
      {:tls_fingerprint, 't'},
    ], sticky: true)

    # The gate of every strip's Mark sub-tab row (#1274): on its own tab, with a second chip to
    # mark alongside — the same gate as Mark all. Shared so nine registrations spell it once.
    def self.subtab_mark_ready(tab : Symbol) : Verb::ExecContext -> Bool
      ->(ctx : Verb::ExecContext) { ctx.current_tab == tab && ctx.subtab_search_count >= 2 }
    end

    def self.register_families(r : Verb::Registry) : Nil
      r.register_family(SEND_FLOW)
      r.register_family(DISPLAY)
      r.register_family(PROTOCOL)
    end
  end
end
