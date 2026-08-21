module Gori
  # Where a stored flow CAME FROM — which gori tool put the request on the wire, through which
  # surface, and (when the tool has one) which of its sessions.
  #
  # History is read as evidence, and until this existed six different producers wrote into
  # `flows` with nothing on the row telling them apart: the capture proxy, MCP `send_request`
  # (whose `record_history` defaults to TRUE), a Discover crawl (on by default), an opt-in
  # `--record-history` fuzz sweep or repeater send, and `import`. A response gori's own Repeater
  # elicited and a response the target's client really received were byte-identical here, which
  # is the same class of problem `short_circuited` (the PROTO column's `STUB`) was added to fix
  # one layer down — except that one is about a response gori FABRICATED, and this one is about
  # a request gori SENT.
  #
  # This module is the single source of truth for the History SRC column's label, the value the
  # QL `src:` filter accepts, and the token on disk — the same contract `Gori::Proto` keeps for
  # the PROTO column. `Proto` gets it for free because its label and its filter value are the
  # same string; here they are NOT (the column has five cells and `repeater` does not fit), so
  # `parse?` accepts BOTH spellings and a spec pins the two tables against the enum. Someone who
  # reads `RPTR` off the screen and types `src:rptr` must get the rows they just looked at.
  module FlowSource
    # The tool that produced the flow. Stored as `#token` in `flows.source` (TEXT).
    #
    # TEXT and not the integer enum value (`FlowState`'s storage), because this vocabulary is
    # open-ended in a way a lifecycle is not — every workbench that learns to record adds a
    # member — and a token keeps a `sqlite3` dump, a HAR comment and an MCP payload readable
    # without a lookup table. It also survives a reordering of the enum, which an integer does
    # not.
    enum Kind
      # The capture proxy relayed a client's request. The one member whose request did not
      # originate inside gori at all.
      Proxy
      Repeater
      Fuzzer
      Miner
      Sequencer
      Discover
      Authorize
      Probe
      # Read out of a file someone else captured (HAR, Burp, `--urls`, an OpenAPI document).
      # Deliberately NOT `sent_by_gori?`: gori never put these on a wire, and calling them its
      # own traffic would answer "is this evidence about the target?" the wrong way.
      Import

      # The stored + QL spelling. Every member is one word, so this is its lowercase name.
      def token : String
        to_s.underscore
      end

      # The History SRC column's tag. At most 5 cells — the column is fixed-width, and the
      # widths are pinned by a spec.
      #
      # An exhaustive `case` and not a lookup table with a fallback: a member added without a
      # tag must be a compile error, not a row that silently renders as `PROXY`. (`RulePart#badge`
      # makes the same argument for the same reason.)
      def label : String
        case self
        in Proxy     then "PROXY"
        in Repeater  then "RPTR"
        in Fuzzer    then "FUZZ"
        in Miner     then "MINER"
        in Sequencer then "SEQ"
        in Discover  then "CRAWL"
        in Authorize then "AUTHZ"
        in Probe     then "PROBE"
        in Import    then "IMPRT"
        end
      end

      # Did gori itself put this request on the wire?
      #
      # Three-way, not two: `Proxy` is the client's traffic, `Import` is someone else's capture,
      # and everything between is gori's. `src:gori` compiles from this predicate, so a new
      # member joins that filter by existing rather than by remembering to edit a SQL string.
      def sent_by_gori? : Bool
        case self
        in Proxy, Import                                                  then false
        in Repeater, Fuzzer, Miner, Sequencer, Discover, Authorize, Probe then true
        end
      end

      # Parse a QL `src:` value or a stored token. Accepts the `#token` spelling AND the SRC
      # column's `#label`, case-insensitively — see the module comment for why both.
      def self.parse?(value : String) : Kind?
        v = value.downcase
        values.find { |k| k.token == v || k.label.downcase == v }
      end

      # Every `#token`, in declaration order — the QL value-completion pool and the docs read
      # this rather than spelling the list out again.
      def self.tokens : Array(String)
        values.map(&.token)
      end
    end

    # The gori surface the request was issued from. Stored as `#token` in
    # `flows.source_surface` (TEXT).
    #
    # NULL means "no gori surface originated this" — a proxy capture, where the request came
    # from the client's own program — or, on a row written before the column existed, "not
    # recorded". `flows.source` being NULL is what tells those two apart.
    enum Surface
      Tui
      Cli
      Mcp

      def token : String
        to_s.underscore
      end

      def label : String
        token.upcase
      end

      def self.parse?(value : String) : Surface?
        v = value.downcase
        values.find { |s| s.token == v }
      end
    end
  end
end
