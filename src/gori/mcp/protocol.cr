module Gori
  module MCP
    # WHICH revision of MCP this server speaks, and how one request says which one it means.
    #
    # MCP has two eras. Through `2025-11-25` a session opens with an `initialize` handshake
    # and every message after it inherits the version negotiated there. `2026-07-28` removed
    # the handshake: the protocol is stateless, each request carries its own version and the
    # client's capabilities in `_meta`, every result names its `resultType`, and
    # `server/discover` is the one RPC a server MUST implement so a client can ask what it is
    # talking to before it commits to anything.
    #
    # gori is DUAL-ERA, which is the shape the spec itself prescribes for serving both: a
    # request carrying modern per-request metadata is answered under `2026-07-28`, an
    # `initialize` selects legacy semantics for the client that sent it, and the two coexist
    # in one process. The era decides the ENVELOPE — `resultType`, `_meta` server identity,
    # cache hints — and never what a tool does: `tools/call` dispatches into the same handler
    # either way, so there is no second surface to keep in step (DESIGN.md §2).
    #
    # The era is read per request and never latched, because under the modern revision there
    # is nothing to latch it to: "an open connection is not a session", and a client may
    # interleave requests from unrelated conversations on one stdio process.
    module Protocol
      # Revisions that carry version, identity and capabilities per request.
      MODERN_VERSIONS = {"2026-07-28"}

      # Handshake revisions. gori's surface (initialize / tools.list / tools.call / ping) is
      # identical across all four — it uses none of the features that separate them
      # (resources, prompts, sampling, elicitation, tasks) — so each is answered by echoing
      # it back rather than by negotiating down.
      LEGACY_VERSIONS = {"2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"}

      # Newest first: what `server/discover` advertises, and what an
      # `UnsupportedProtocolVersionError` carries as `data.supported` for the client to pick
      # a retry from.
      SUPPORTED_VERSIONS = MODERN_VERSIONS + LEGACY_VERSIONS

      # The newest revision we implement, for anything that wants one number to print.
      LATEST = MODERN_VERSIONS.first

      # What an `initialize` is answered with when the client asked for a revision we do not
      # know. The spec says answer with a version we do support and SHOULD make it the
      # latest — the latest LEGACY one, because `initialize` IS the legacy opening: naming a
      # modern version there would promise per-request semantics to a client that has
      # already opened a handshake session and cannot switch.
      LEGACY_LATEST = LEGACY_VERSIONS.first

      # `_meta` keys the spec reserves for itself. Any prefix whose second label is
      # `modelcontextprotocol` or `mcp` belongs to MCP, so these are not names to invent
      # near a call site.
      META_PREFIX           = "io.modelcontextprotocol/"
      META_PROTOCOL_VERSION = "#{META_PREFIX}protocolVersion"
      META_CLIENT_INFO      = "#{META_PREFIX}clientInfo"
      META_CLIENT_CAPS      = "#{META_PREFIX}clientCapabilities"
      META_SERVER_INFO      = "#{META_PREFIX}serverInfo"
      META_SUBSCRIPTION_ID  = "#{META_PREFIX}subscriptionId"

      # `resultType` on a result that is the final answer. The other member of the set,
      # `input_required`, belongs to multi round-trip requests — a server asking the client
      # for sampling, roots or elicitation mid-call. gori asks for none of those: every tool
      # answers from the project store or the wire, so `complete` is the only type it emits.
      RESULT_COMPLETE = "complete"

      # `UnsupportedProtocolVersionError`. `-32020`..`-32099` is the band the 2026-07-28
      # spec reserved for itself; an implementation MUST NOT mint its own codes inside it,
      # and MUST use the ones defined there only with their defined meaning.
      UNSUPPORTED_PROTOCOL_VERSION = -32022

      # How long a client MAY treat `tools/list` as fresh, ONCE the catalogue has settled —
      # `Server#tool_list_ttl_ms` answers zero while it can still move. Settled, it is a pure
      # function of this process's start-up flags (`--read-only`, `--tools`), so the honest
      # answer is "until this process ends", which is not expressible. Five minutes is the
      # compromise: it spares a long agent session the re-fetch, and an operator who restarts
      # gori with a different `--tools` sees the new catalogue within one.
      TOOLS_LIST_TTL_MS = 300_000

      # …and `server/discover` gets zero, because its `instructions` name the project this
      # server is bound to and `switch_project` moves that binding mid-session (#1003). A
      # cached discovery would go on naming the project the agent has already left. The
      # re-fetch it costs is one small call that a client makes at most once per turn.
      DISCOVER_TTL_MS = 0

      # `private`, not `public`, on everything we cache-hint. A cached response is keyed by
      # method plus params, and `{"method":"tools/list"}` is the same key for every gori
      # process on the machine — so a shared intermediary told `public` could serve one
      # operator's `--tools`-narrowed catalogue, or another project's instructions, to a
      # different server's client. Nothing here is user-specific data; it is
      # SERVER-specific, which the cache key cannot see.
      CACHE_SCOPE = "private"

      # A revision that carries its version per request (this server answers it statelessly).
      def self.modern?(version : String) : Bool
        MODERN_VERSIONS.includes?(version)
      end

      # A revision whose session is opened by `initialize`.
      def self.legacy?(version : String) : Bool
        LEGACY_VERSIONS.includes?(version)
      end

      def self.supported?(version : String) : Bool
        modern?(version) || legacy?(version)
      end
    end
  end
end
