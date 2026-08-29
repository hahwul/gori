require "./flow_source"

module Gori
  # #864: record a CONFIGURATION change into the event feed.
  #
  # The feed already carried what the AGENT did (`log_agent_action` wraps every mutating MCP
  # tool) and what the background engines found. What it could not say is what the HUMAN
  # changed: `Scope#add`, `HostOverrides#update`, a Match & Replace edit and the sandbox toggle
  # all wrote to the store and told the log nothing, so an audit of "what happened to this
  # project" was missing every change made from the TUI or `gori run`.
  #
  # Recorded at the MODEL, not at the surfaces. All three reach the same `Scope`/`HostOverrides`
  # /`Rules` object — `Scope.load` alone has 26 construction sites — so a per-surface producer
  # would be three copies, and the CLI is the one that gets forgotten. One site per change
  # covers TUI, CLI and MCP at once; `actor` (defaulted from `FlowSource.surface`) is what tells
  # them apart afterwards.
  module ConfigLog
    # An MCP-driven change is recorded TWICE, and on purpose: `log_agent_action` writes
    # `agent | "add_scope_rule ok"` (the call and its outcome, including the refusals a config
    # event never sees) and this writes `config | "scope rule added — include host …"` (the
    # VALUE, which the tool name cannot carry). They answer different questions, they carry the
    # same `actor`, and the pane's source chip separates them — a single row would have to drop
    # one of the two halves.

    # The feed `source` these share. One token, so the Activity pane's chip and MCP's
    # `list_events{source}` can both name "someone changed a setting" in one word.
    SOURCE = "config"

    # Values are ECHOED into the message, so anything that could carry a credential must be
    # scrubbed at the site that knows it is one — never here, where the field's meaning is gone.
    # This is the placeholder those sites use, so a scrubbed value is legible as scrubbed rather
    # than as an empty setting.
    REDACTED = "••••"

    # A proxy URL with any userinfo replaced. `http://bob:hunter2@corp:8080` is the shape an
    # operator pastes when a proxy needs auth, and echoing it verbatim would put the password in
    # the very log the audit trail exists to be. Nothing else about the URL is hidden — the
    # host is the fact the line is FOR.
    # Userinfo lives in the AUTHORITY only — between `://` and the first `/`, `?` or `#`. A bare
    # `rindex('@')` reaches past it, so `http://corp.example/a@b` came back as `http://••••@b`:
    # the host, which is the fact the line exists to record, replaced by the redaction of
    # something that was never a credential.
    def self.scrub_url(url : String) : String
      return url unless sep = url.index("://")
      start = sep + 3
      stop = url.index(/[\/?#]/, start) || url.size
      at = url.rindex('@', stop - 1)
      return url unless at && at >= start
      "#{url[0, start]}#{REDACTED}@#{url[(at + 1)..]}"
    end

    # Best-effort, like `log_agent_action`: a change that happened must not be undone (nor its
    # caller failed) because the log of it could not be written.
    #
    # Call ONLY after the write is known to have COMMITTED. Every `add`/`update` on these models
    # returns whether the store accepted it — several of them had to be fixed to do so — and
    # recording an attempt as a change would put a rule in the audit trail that never gated a
    # single request.
    # A config change that did not fully land. Separate from `record` because the LEVEL is the
    # point: a half-applied setting is not a normal entry in the log, it is something the
    # operator has to go and settle.
    def self.warn(store : Store, kind : String, message : String) : Nil
      store.insert_event(SOURCE, kind, "warn", message, actor: FlowSource.surface.try(&.token))
    rescue ex
      Log.warn(exception: ex) { "event feed: failed to log config warning #{kind}" }
    end

    def self.record(store : Store, kind : String, message : String) : Nil
      # The ambient surface, passed EXPLICITLY. A config change is by definition something a
      # surface did, which is exactly what makes it safe to claim here and unsafe as a default
      # on `insert_event` (see the note there).
      store.insert_event(SOURCE, kind, "info", message, actor: FlowSource.surface.try(&.token))
    rescue ex
      Log.warn(exception: ex) { "event feed: failed to log config change #{kind}" }
    end
  end
end
