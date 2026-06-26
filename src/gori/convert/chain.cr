module Gori::Convert
  enum StepState
    Ok      # ran, produced output
    Failed  # converter raised, or its output exceeded MAX_OUT
    Unknown # the token didn't resolve to a converter
    Skipped # an earlier step failed, so this one wasn't run
  end

  # The result of one chain step. `output` carries this step's intermediate bytes
  # (the Pipeline notebook draws every step's output); `error` carries the message
  # for a Failed/Unknown step.
  struct StepResult
    getter token : String         # the token exactly as typed
    getter converter : Converter? # resolved converter (nil when Unknown)
    getter state : StepState
    getter output : Bytes?
    getter error : String?

    def initialize(@token, @converter, @state, @output = nil, @error = nil)
    end

    def ok? : Bool
      @state.ok?
    end

    # Canonical converter name for display; falls back to the raw token (Unknown).
    def name : String
      @converter.try(&.name) || @token
    end
  end

  # The whole chain run: the input plus one StepResult per token.
  struct ChainResult
    getter input : Bytes
    getter steps : Array(StepResult)

    def initialize(@input, @steps)
    end

    # Final output: an empty chain is the identity (output == input); otherwise the
    # last step's output (nil when the last step didn't run/produce).
    def output : Bytes?
      @steps.empty? ? @input : @steps.last.output
    end

    def ok? : Bool
      @steps.all?(&.ok?)
    end

    # The first non-Ok step (for the UI to highlight), or nil.
    def failed_at : Int32?
      @steps.index { |s| !s.ok? }
    end
  end

  # Chain separators: '>', '|', ',' — all equivalent, left-to-right.
  SEPARATORS = /[>|,]/

  def self.parse_spec(spec : String) : Array(String)
    spec.split(SEPARATORS).map(&.strip).reject(&.empty?)
  end

  # Run `input` through the parsed chain. NEVER raises: a converter raise becomes a
  # Failed StepResult and stops the pipeline; tokens after a stop are Skipped so the
  # notebook can still render their rows. An empty spec yields no steps (identity).
  def self.run(registry : Registry, input : Bytes, spec : String, max_out : Int32 = MAX_OUT) : ChainResult
    tokens = parse_spec(spec)
    steps = Array(StepResult).new(tokens.size)
    current = input
    stopped = false

    tokens.each do |tok|
      if stopped
        steps << StepResult.new(tok, registry[tok]?, StepState::Skipped)
        next
      end
      conv = registry[tok]?
      if conv.nil?
        steps << StepResult.new(tok, nil, StepState::Unknown, error: "unknown converter")
        stopped = true
        next
      end
      begin
        produced = conv.apply(current)
        if produced.size > max_out
          steps << StepResult.new(tok, conv, StepState::Failed, error: "output exceeds #{max_out} bytes")
          stopped = true
        else
          steps << StepResult.new(tok, conv, StepState::Ok, output: produced)
          current = produced
        end
      rescue ex : ConvertError
        steps << StepResult.new(tok, conv, StepState::Failed, error: ex.message)
        stopped = true
      rescue ex
        steps << StepResult.new(tok, conv, StepState::Failed, error: ex.message || "error")
        stopped = true
      end
    end

    ChainResult.new(input, steps)
  end
end
