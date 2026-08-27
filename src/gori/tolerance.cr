module Gori
  # The calibration BAND: how far a response metric may move before the move counts as a
  # real change rather than the page's own churn.
  #
  # One formula, three callers. `Repeater::Minimize` and `Miner::Baseline` each held a
  # verbatim copy (the first one's comment even said "same formula as Miner::Baseline"),
  # and the retest diff (`Gori::Diff`) needs the same notion at endpoint scale. Three
  # copies of a tolerance rule is how two surfaces end up disagreeing about whether a
  # response changed — the one question all three exist to answer.
  #
  # The rule: a band is 2x the observed jitter across the samples, floored by a
  # size-PROPORTIONAL minimum (1% of the reference value) so a page that happened to
  # measure identically twice still tolerates small natural churn, with a fixed floor
  # underneath it so a tiny response never gets a zero-width band.
  module Tolerance
    # Fixed floors per metric — the smallest band each may have, before the proportional
    # term takes over. Bytes are noisier than lines, hence the descending scale.
    LENGTH_FLOOR = 8_i64
    WORDS_FLOOR  =     3
    LINES_FLOOR  =     2

    # 2x the observed jitter (`max - min`), floored at `max(floor, base / 100)`.
    def self.band(min : Int64, max : Int64, base : Int64, floor : Int64) : Int64
      {(max - min) * 2, {floor, base // 100}.max}.max
    end

    # :ditto:
    def self.band(min : Int32, max : Int32, base : Int32, floor : Int32) : Int32
      {(max - min) * 2, {floor, base // 100}.max}.max
    end
  end
end
