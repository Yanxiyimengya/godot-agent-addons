@abstract
class_name ChatSDK;
extends RefCounted;

@abstract
func generate_request_url(config : AgentConfig) -> String;

@abstract
func generate_header(config : AgentConfig) -> PackedStringArray;

@abstract
func generate_context_request(context : AgentContext) -> Dictionary;

@abstract
func generate_compression_request(
	config : AgentConfig,
	existing_summary : String,
	messages : Array[AgentMessage]
) -> Dictionary;

@abstract
func estimate_message_tokens(config : AgentConfig, messages : Array[AgentMessage]) -> int;

@abstract
func parse_error_body(body : String, http_status : int, source : String) -> AgentError;

@abstract
func phrase_response(json : Dictionary) -> Array[AgentAssistantMessage];

@abstract
func update_stream(ms : AgentAssistantMessageStream, json : Dictionary) -> void;

@abstract
func process_stream(ms : AgentAssistantMessageStream) -> void;
