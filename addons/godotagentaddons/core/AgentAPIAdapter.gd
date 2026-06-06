class_name AgentAPIAdapter;
extends RefCounted;

var sdk : ChatSDK;

func generate_request_url(config : AgentConfig) -> String:
	return sdk.generate_request_url(config);

func generate_header(config : AgentConfig) -> PackedStringArray:
	return sdk.generate_header(config);

func generate_context_request(context : AgentContext) -> Dictionary:
	return sdk.generate_context_request(context);

func generate_compression_request(
	config : AgentConfig,
	existing_summary : String,
	messages : Array[AgentMessage]
) -> Dictionary:
	return sdk.generate_compression_request(config, existing_summary, messages);

func estimate_message_tokens(config : AgentConfig, messages : Array[AgentMessage]) -> int:
	return sdk.estimate_message_tokens(config, messages);

func parse_error_body(body : String, http_status : int = 0, source : String = "Agent") -> AgentError:
	return sdk.parse_error_body(body, http_status, source);

func phrase_response_body(body : String) -> Array[AgentAssistantMessage]:
	var result : Array[AgentAssistantMessage] = [];
	var body_text : String = body.strip_edges();
	if (body_text.is_empty()) :
		push_warning("Agent response body is empty.");
		return result;
	
	var json : JSON = JSON.new();
	var parse_error : Error = json.parse(body_text);
	if (parse_error != OK) :
		push_warning("Parse agent response JSON failed: %s" % [json.get_error_message()]);
		return result;
	if (typeof(json.data) != TYPE_DICTIONARY) :
		push_warning("Agent response JSON root is not an object.");
		return result;
	return sdk.phrase_response(json.data);

func update_message_stream(ms : AgentAssistantMessageStream, json : Dictionary) -> void:
	sdk.update_stream(ms, json);
	ms.stream_updated.emit();

func close_message_stream(ms : AgentAssistantMessageStream) -> void:
	sdk.process_stream(ms);
	ms.close();
