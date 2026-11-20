require "json"
require "crypto/subtle"
require "./fuzz/payload"

module Gori::SecretCrack
  # Inline candidates precede the lazy file; WordlistFile owns saved-name resolution.
  record Candidates, inline : Array(String), wordlist : String? = nil do
    def each(& : String ->) : Nil
      inline.each { |candidate| yield candidate }
      if path = wordlist
        Fuzz::WordlistFile.new(path).each { |candidate| yield candidate }
      end
    end
  end

  record Result, secret : String?, tried : Int64, stopped : Bool = false do
    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "found", !secret.nil?
        json.field "secret", secret if secret
        json.field "tried", tried
        json.field "stopped", stopped
      end
    end
  end

  # Large signing inputs make a candidate stride expensive; share a 10 ms time slice too.
  # Stop is checked again after yielding, before charging or signing the next candidate.
  def self.search(secrets, signature : String, stop : Proc(Bool)? = nil, & : String -> String) : Result
    tried = 0_i64
    last_yield = Time.instant
    secrets.each do |candidate|
      if (tried + 1) % 4096 == 0 || Time.instant - last_yield >= 10.milliseconds
        Fiber.yield
        last_yield = Time.instant
      end
      return Result.new(nil, tried, stopped: true) if stop.try(&.call)
      tried += 1
      return Result.new(candidate, tried) if Crypto::Subtle.constant_time_compare(yield(candidate), signature)
    end
    Result.new(nil, tried, stopped: !!stop.try(&.call))
  end
end
