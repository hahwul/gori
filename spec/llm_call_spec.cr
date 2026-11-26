require "./spec_helper"

private REQ_HEAD = "POST /v1/x HTTP/1.1\r\nHost: llm.test\r\nContent-Type: application/json\r\n\r\n".to_slice

private def llm(req : String, resp : String, ct = "application/json") : Gori::LlmCall::Call?
  Gori::LlmCall.from_flow(REQ_HEAD, req.to_slice,
    "HTTP/1.1 200 OK\r\nContent-Type: #{ct}\r\n\r\n".to_slice, resp.to_slice)
end

private def sse(events : Array(String)) : String
  events.map { |e| "data: #{e}\n\n" }.join + "data: [DONE]\n\n"
end

private def anthropic_sse(events : Array({String, String})) : String
  events.map { |(t, d)| "event: #{t}\ndata: #{d}\n\n" }.join
end

private CHAT_REQ = %({"model":"gpt-4o","messages":[{"role":"system","content":"s"},{"role":"user","content":"a"},) +
                   %({"role":"user","content":"b"}],"tools":[{"type":"function","function":{"name":"get_weather"}}]})

private ANTHROPIC_REQ = %({"model":"claude-x","max_tokens":10,"system":"s","messages":[{"role":"user","content":"hi"}],) +
                        %("tools":[{"name":"get_weather","input_schema":{}}]})

# Asserts the streamed reply reassembled to exactly what the non-streamed one carried.
private def same_reply(a : Gori::LlmCall::Call, b : Gori::LlmCall::Call) : Nil
  a.text.should eq(b.text)
  a.tool_calls.should eq(b.tool_calls)
  a.stop.should eq(b.stop)
  a.usage.should eq(b.usage)
  a.model.should eq(b.model)
  a.dialect.should eq(b.dialect)
end

describe Gori::LlmCall do
  it "reads an OpenAI chat completion and reassembles its stream to the same reply" do
    whole = llm(CHAT_REQ, %({"object":"chat.completion","model":"gpt-4o-2024","choices":[{"index":0,) +
                          %("message":{"role":"assistant","content":"Let me check.","tool_calls":[{"id":"c1",) +
                          %("type":"function","function":{"name":"get_weather","arguments":"{\\"city\\":\\"Seoul\\"}"}}]},) +
                          %("finish_reason":"tool_calls"}],"usage":{"prompt_tokens":9,"completion_tokens":5}})).not_nil!
    whole.dialect.should eq("openai-chat")
    whole.model.should eq("gpt-4o-2024")
    whole.roles.should eq("system, user ×2")
    whole.tools.should eq(["get_weather"])
    whole.text.should eq("Let me check.")
    whole.tool_calls.map(&.name).should eq(["get_weather"])
    whole.tool_calls[0].arguments.should contain(%("city": "Seoul"))
    whole.stop.should eq("tool_calls")
    JSON.parse(whole.usage.not_nil!)["completion_tokens"].should eq(5)
    whole.streamed.should be_false

    streamed = llm(CHAT_REQ, sse([
      %({"model":"gpt-4o-2024","choices":[{"index":0,"delta":{"role":"assistant","content":"Let me"}}]}),
      %({"model":"gpt-4o-2024","choices":[{"index":0,"delta":{"content":" check."}}]}),
      %({"model":"gpt-4o-2024","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"get_weather","arguments":"{\\"ci"}}]}}]}),
      %({"model":"gpt-4o-2024","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ty\\":\\"Seoul\\"}"}}]}}]}),
      %({"model":"gpt-4o-2024","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}),
      %({"model":"gpt-4o-2024","choices":[],"usage":{"prompt_tokens":9,"completion_tokens":5}}),
    ]), "text/event-stream").not_nil!
    streamed.streamed.should be_true
    same_reply(streamed, whole)
  end

  it "reads an Anthropic message and reassembles its stream to the same reply" do
    whole = llm(ANTHROPIC_REQ, %({"type":"message","model":"claude-x-1","content":[{"type":"text","text":"On it."},) +
                               %({"type":"tool_use","id":"t1","name":"get_weather","input":{"city":"Seoul"}}],) +
                               %("stop_reason":"tool_use","usage":{"input_tokens":12,"output_tokens":7}})).not_nil!
    whole.dialect.should eq("anthropic")
    whole.roles.should eq("system, user")
    whole.text.should eq("On it.")
    whole.tool_calls[0].name.should eq("get_weather")
    whole.stop.should eq("tool_use")

    streamed = llm(ANTHROPIC_REQ, anthropic_sse([
      {"message_start", %({"type":"message_start","message":{"model":"claude-x-1","content":[],"usage":{"input_tokens":12,"output_tokens":1}}})},
      {"content_block_start", %({"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}})},
      {"content_block_delta", %({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"On "}})},
      {"content_block_delta", %({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"it."}})},
      {"content_block_start", %({"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"get_weather","input":{}}})},
      {"content_block_delta", %({"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"city\\": "}})},
      {"content_block_delta", %({"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"Seoul\\"}"}})},
      {"message_delta", %({"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}})},
      {"message_stop", %({"type":"message_stop"})},
    ]), "text/event-stream").not_nil!
    same_reply(streamed, whole)
    Gori::LlmCall.summary(streamed).should eq("anthropic · claude-x-1 · streamed · 1 tool call · tool_use")

    # A tool called with no arguments keeps its `{}` when the message is whole.
    empty = llm(ANTHROPIC_REQ, %({"type":"message","content":[{"type":"tool_use","name":"now","input":{}}]})).not_nil!
    empty.tool_calls[0].arguments.should eq("{}")
  end

  it "takes an OpenAI responses stream's final event over its deltas" do
    req = %({"model":"gpt-5","input":"hi"})
    streamed = llm(req, sse([
      %({"type":"response.output_text.delta","delta":"Hel"}),
      %({"type":"response.output_text.delta","delta":"lo"}),
      %({"type":"response.completed","response":{"object":"response","model":"gpt-5-x","status":"completed",) +
      %("output":[{"type":"message","content":[{"type":"output_text","text":"Hello"}]}],"usage":{"total_tokens":3}}}),
    ]), "text/event-stream").not_nil!
    streamed.dialect.should eq("openai-responses")
    streamed.roles.should eq("user")
    streamed.text.should eq("Hello")
    streamed.model.should eq("gpt-5-x")
    streamed.stop.should eq("completed")
  end

  it "decodes a responses stream cut off mid function call" do
    req = %({"model":"gpt-5","input":"weather?"})
    cut = llm(req, sse([
      %({"type":"response.created","response":{"object":"response","status":"in_progress","output":[]}}),
      %({"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","name":"get_weather","arguments":""}}),
      %({"type":"response.function_call_arguments.delta","output_index":1,"delta":"{\\"city\\":"}),
      %({"type":"response.function_call_arguments.delta","output_index":1,"delta":"\\"Seoul\\"}"}),
    ]), "text/event-stream").not_nil!
    cut.dialect.should eq("openai-responses")
    cut.tool_calls.map(&.name).should eq(["get_weather"])
    cut.tool_calls[0].arguments.should contain(%("city": "Seoul"))
  end

  it "offers nothing for a plain REST body" do
    llm(%({"name":"shoes","messages":[]}), %({"ok":true})).should be_nil
    llm(%({"model":"x"}), %({"ok":true})).should be_nil
    llm("not json", "").should be_nil
  end

  it "never raises on replies of the wrong shape" do
    ["[1]", "5", %({"choices":{}}), %({"choices":[5]}), %({"choices":[{"message":5}]}),
     %({"type":"message","content":[1,{"type":"tool_use","input":3}]}),
     %({"type":"content_block_delta","index":3000000000,"delta":{"partial_json":"x"}}),
     %({"type":"response.completed","response":5}), %({"type":"response.output_item.added","item":5}),
     %({"type":"response.function_call_arguments.delta","output_index":"x","delta":3})].each do |resp|
      llm(CHAT_REQ, resp)
      llm(CHAT_REQ, "data: #{resp}\n\n", "text/event-stream")
    end
    llm(%({"model":"m","messages":[1,"x"],"tools":[2]}), "").not_nil!.roles.should eq("? ×2")
  end

  it "is not an LLM call when a model+input request got a non-Responses reply (embeddings)" do
    llm(%({"model":"text-embedding-3-small","input":"hi"}), %({"object":"list","data":[]})).should be_nil
    llm(%({"model":"gpt-5","input":"hi"}), "").should_not be_nil # no reply yet
  end

  it "reads only the first choice of an n>1 stream" do
    c = llm(CHAT_REQ, sse([
      %({"choices":[{"index":0,"delta":{"content":"A"}}]}),
      %({"choices":[{"index":1,"delta":{"content":"B"}}]}),
    ]), "text/event-stream").not_nil!
    c.text.should eq("A")
  end

  it "reassembles a streamed reply from the response alone, tool calls included" do
    head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".to_slice
    body = sse([
      %({"choices":[{"index":0,"delta":{"content":"PW"}}]}),
      %({"choices":[{"index":0,"delta":{"content":"NED","tool_calls":[{"index":0,"function":{"name":"send_mail","arguments":"{\\"to\\":\\"evil"}}]}}]}),
      %({"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"@x.test\\"}"}}]}}]}),
    ]).to_slice
    # The model's own bytes: arguments are not re-indented and no heading is added.
    Gori::LlmCall.stream_reply(head, body).should eq(%(PWNED\nsend_mail\n{"to":"evil@x.test"}))
    # Not a stream, and a stream that is not an LLM reply.
    json = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n".to_slice
    Gori::LlmCall.stream_reply(json, %({"choices":[{"index":0,"message":{"content":"x"}}]}).to_slice).should be_nil
    Gori::LlmCall.stream_reply(head, "data: {\"tick\":1}\n\n".to_slice).should be_nil
    Gori::LlmCall.stream_reply(nil, Bytes.empty).should be_nil
  end

  it "writes a call as a Markdown transcript: each request message, then the reply" do
    head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n".to_slice
    req = %({"model":"claude-x","system":[{"type":"text","text":"Be brief."}],"messages":[) +
          %({"role":"user","content":"weather?"},) +
          %({"role":"assistant","content":[{"type":"tool_use","name":"get_weather","input":{"city":"Seoul"}}]},) +
          %({"role":"user","content":[{"type":"tool_result","content":[{"type":"text","text":"12C"}]},{"type":"image"}]}]})
    resp = %({"type":"message","model":"claude-x","content":[{"type":"text","text":"12C in Seoul."},) +
           %({"type":"tool_use","name":"log","input":{}}],"stop_reason":"tool_use"})
    Gori::LlmCall.transcript(REQ_HEAD, req.to_slice, head, resp.to_slice).should eq(<<-MD)
      # LLM call: anthropic · claude-x · 1 tool call · tool_use

      ## system

      Be brief.

      ## user

      weather?

      ## assistant

      [tool call get_weather] {"city":"Seoul"}

      ## user

      [tool result] 12C
      [image]

      ## assistant

      12C in Seoul.

      ### tool call: log

      ```json
      {}
      ```

      MD
  end

  it "reads chat tool calls and a Responses input into the transcript, and nothing from a REST body" do
    chat = %({"model":"gpt-4o","messages":[{"role":"assistant","content":null,"tool_calls":[{"function":) +
           %({"name":"f","arguments":"{}"}}]},{"role":"tool","content":"ok"}]})
    Gori::LlmCall.transcript(REQ_HEAD, chat.to_slice, nil, nil).should eq(
      "# LLM call: openai-chat · gpt-4o\n\n## assistant\n\n[tool call f] {}\n\n## tool\n\nok\n")
    responses = %({"model":"gpt-5","instructions":"Be brief.","input":[{"role":"user","content":) +
                %([{"type":"input_text","text":"hi"}]},{"type":"function_call","name":"f","arguments":"{}"},) +
                %({"type":"function_call_output","output":"ok"},7]})
    Gori::LlmCall.transcript(REQ_HEAD, responses.to_slice, nil, nil).should eq(
      "# LLM call: openai-responses · gpt-5\n\n## system\n\nBe brief.\n\n## user\n\nhi\n\n" \
      "## function_call\n\n[tool call f] {}\n\n## function_call_output\n\nok\n")
    Gori::LlmCall.transcript(REQ_HEAD, %({"model":"gpt-5","input":"hi"}).to_slice, nil, nil).should eq(
      "# LLM call: openai-responses · gpt-5\n\n## user\n\nhi\n")
    Gori::LlmCall.transcript(REQ_HEAD, %({"model":"sedan","year":2020}).to_slice, nil, nil).should be_nil
  end

  # `JSON.parse` rejects a whole document over one number past Int64/Float64: a uint64 `seed`
  # hid the call, a bignum in `usage` emptied the reply, and a streamed event carrying one was
  # dropped from the text the Fuzzer matches. What is shown as JSON keeps the digits as sent.
  describe "numbers past Int64/Float64" do
    big = "18446744073709551615"

    it "still decodes a request carrying one" do
      req = %({"model":"gpt-4o","seed":#{big},"messages":[{"role":"user","content":"hi"}]})
      c = llm(req, %({"choices":[{"index":0,"message":{"content":"ok"}}]})).not_nil!
      c.model.should eq("gpt-4o")
      c.roles.should eq("user")
      c.text.should eq("ok")
    end

    it "keeps the reply, and shows usage with the number unquoted" do
      c = llm(CHAT_REQ, %({"choices":[{"index":0,"message":{"content":"ok"}}],"usage":{"total_tokens":#{big},"f":1.0e2}})).not_nil!
      c.text.should eq("ok")
      c.usage.should eq(%({"total_tokens":#{big},"f":1.0e2}))
      Gori::LlmCall.display(c).should contain(%("total_tokens":#{big}))
    end

    it "shows an Anthropic tool_use input with the number unquoted, past a non-object block" do
      resp = %({"type":"message","content":[7,{"type":"tool_use","name":"a","input":{"id":#{big}}},) +
             %({"type":"tool_use","name":"b","input":{"n":1}}],"stop_reason":"tool_use"})
      c = llm(ANTHROPIC_REQ, resp).not_nil!
      c.tool_calls.map(&.name).should eq(["a", "b"])
      c.tool_calls[0].arguments.should contain(big)
      c.tool_calls[0].arguments.should_not contain(%("#{big}"))
      c.tool_calls[1].arguments.should_not contain(big)
      req = %({"model":"claude-x","messages":[7,{"role":"assistant","content":[{"type":"tool_use","name":"t","input":{"id":#{big}}}]}]})
      Gori::LlmCall.transcript(REQ_HEAD, req.to_slice, nil, nil).not_nil!.should contain(%([tool call t] {"id":#{big}}))
    end

    it "keeps both members of a duplicated key in chat tool-call arguments" do
      resp = %({"choices":[{"index":0,"message":{"tool_calls":[{"function":{"name":"f","arguments":"{\\"a\\":1,\\"a\\":2}"}}]}}]})
      args = llm(CHAT_REQ, resp).not_nil!.tool_calls[0].arguments
      args.should contain(%("a": 1))
      args.should contain(%("a": 2))
    end

    it "reassembles a stream whose event carries one" do
      head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n".to_slice
      body = sse([
        %({"choices":[{"index":0,"delta":{"content":"sec"}}]}),
        %({"choices":[{"index":0,"delta":{"content":"ret"}}],"x":#{big}}),
      ]).to_slice
      Gori::LlmCall.stream_reply(head, body).should eq("secret")
    end

    # A number past Int64 is not a string: where a JSON string is required (model, input,
    # content), it reads exactly as an ordinary number does, never as text.
    it "does not take one for a string" do
      tr = ->(req : String) { Gori::LlmCall.transcript(REQ_HEAD, req.to_slice, nil, nil) }
      tr.call(%({"model":"x","input":1e400})).should eq(tr.call(%({"model":"x","input":5})))
      tr.call(%({"model":"x","input":1e400})).not_nil!.should_not contain("1e400")
      llm(%({"model":#{big},"messages":[]}), "{}").should be_nil
      c = llm(%({"model":"x","messages":[{"role":"user","content":#{big}}]}), %({"choices":[{"index":0,"message":{"content":#{big}}}]})).not_nil!
      c.text.should eq("")
      tr.call(%({"model":"x","messages":[{"role":#{big},"content":#{big}}]})).not_nil!.should_not contain(big)
    end
  end
end
