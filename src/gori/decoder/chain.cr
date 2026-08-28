module Gori::Decoder
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
      # An `exec:` step is an EXTERNAL COMMAND, not a converter (#818) — checked before the
      # registry so a command whose argv happens to spell a converter name still runs as a
      # command. See `Decoder::EXEC_PREFIX`.
      if Decoder.exec_step?(tok)
        step = exec_step(tok, current, max_out)
        steps << step
        if step.ok?
          current = step.output || current
        else
          stopped = true
        end
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
      rescue ex : DecoderError
        steps << StepResult.new(tok, conv, StepState::Failed, error: ex.message)
        stopped = true
      rescue ex
        steps << StepResult.new(tok, conv, StepState::Failed, error: ex.message || "error")
        stopped = true
      end
    end

    ChainResult.new(input, steps)
  end

  # Run one `exec:` step: the running value goes to the command on stdin, its stdout becomes
  # the step's output.
  #
  # A FAILURE STOPS THE CHAIN, and that is the right disposition HERE even though the Rewriter's
  # `pipe` op passes the original bytes through instead. The two seams answer to different
  # halves of the same principle. The Rewriter sits on the proxy data path, where P6 says a
  # broken hook must never cost the operator a flow — so it degrades to the original octets and
  # writes a notice. The Decoder is an interactive workbench: nothing is in flight, the operator
  # is looking at the PIPELINE pane, and silently carrying the input forward as if the step had
  # run would hand them a value that is not what the chain says it is. A `Failed` row with the
  # reason in it is the honest answer, and it is the one every other converter failure already
  # gives.
  #
  # `max_out` is enforced on top of `ProcessHook::MAX_OUTPUT` because a caller may ask for less
  # (the chain's own per-step ceiling); the hook's cap is the memory bound, this is the chain's.
  private def self.exec_step(token : String, input : Bytes, max_out : Int32) : StepResult
    spec = Decoder.exec_spec(token) || ""
    parsed = ProcessHook.parse_argv(spec)
    return StepResult.new(token, nil, StepState::Failed, error: parsed) if parsed.is_a?(String)
    res = ProcessHook.run(parsed, input, Settings.hook_timeout_secs.seconds,
      {"GORI_HOOK" => "decoder"})
    if reason = res.failure
      return StepResult.new(token, nil, StepState::Failed, error: reason)
    end
    if res.stdout.size > max_out
      return StepResult.new(token, nil, StepState::Failed, error: "output exceeds #{max_out} bytes")
    end
    StepResult.new(token, nil, StepState::Ok, output: res.stdout)
  end
end
