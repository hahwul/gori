module Gori
  # The before-send half of a session slot's refresh (#1233), as the send seams see it.
  #
  # A LEAF on purpose: `Repeater::Sender`, `Fuzz::Sender`, the Discover crawler, the Miner's
  # hook backend and Authorize all ask it, and the thing that answers (`SessionRefresh::Runner`)
  # sends Repeater sessions — so it requires the whole Repeater plan layer. Were the seams to
  # require the runner, `Fuzz::Sender` would depend on the Repeater and every partial bench
  # tree would inherit the cycle. The seams require this file; the runner registers itself.
  #
  # Same lifetime as `Env.layer`, and checked against it rather than trusted to be cleared in
  # step: a hook installed for project A answers nothing once project B's binding table is the
  # layer, so a `switch_project` that forgot to replace it cannot refresh A's slot against B.
  module SessionRefresh
    abstract class Hook
      # Refresh `slot` NOW when its policy says it is due, and return once it is safe to
      # resolve the slot's bindings: after the refresh, after another fiber's in-flight
      # refresh of the same slot, or at once when nothing is due. Never raises and never
      # blocks a send on a failure — the send continues with the value it has.
      abstract def before_send(slot : String) : Nil

      # The binding table this hook refreshes. `SessionRefresh.before_send` compares it to
      # `Env.layer`, so a hook left behind by a closed project is inert.
      abstract def layer : Env::Layer
    end

    @@hook : Hook? = nil

    def self.hook : Hook?
      @@hook
    end

    def self.hook=(h : Hook?) : Hook?
      @@hook = h
    end

    # The seam's one call. `slot` is the identity the send goes out as — the active slot's
    # name at a Repeater/Fuzz send, an Authorize identity's name per trial — and nil (as
    # captured) is the no-op every project without slots takes.
    def self.before_send(slot : String?) : Nil
      return unless slot
      return unless h = @@hook
      return unless h.layer.same?(Env.layer)
      h.before_send(slot)
    end
  end
end
