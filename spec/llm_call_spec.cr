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
    whole.usage.not_nil!["completion_tokens"].should eq(5)
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
end
