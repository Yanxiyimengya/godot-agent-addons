class_name OpenAIChatSDK;
extends ChatSDK;

const SUMMARY_SYSTEM_PROMPT : String = \
"You compress conversation history for an AI agent. Produce a concise but complete summary that preserves user goals, requirements, decisions, constraints, code or tool results, unresolved tasks, and any facts needed to continue the conversation. Do not add new facts.";
const SUMMARY_USER_PROMPT : String = \
"Update the conversation summary. If an existing summary is provided, merge it with the new conversation messages into one fresh summary.\n\nExisting summary:\n%s\n\nNew conversation messages:\n%s";

func generate_request_url(config : AgentConfig) -> String:
	var base_url : String = config.base_url.strip_edges();
	if (base_url.is_empty()) :
		return base_url;

	var query_index : int = base_url.find("?");
	var query : String = "";
	if (query_index >= 0) :
		query = base_url.substr(query_index);
		base_url = base_url.substr(0, query_index);

	var lower_url : String = base_url.to_lower();
	if (lower_url.ends_with("/chat/completions")) :
		return base_url + query;
	if (lower_url.ends_with("/v1")) :
		return base_url + "/chat/completions" + query;
	if (lower_url.ends_with("/")) :
		base_url = base_url.substr(0, base_url.length() - 1);
	return base_url + "/chat/completions" + query;

func generate_header(config : AgentConfig) -> PackedStringArray:
	var headers : PackedStringArray = [
		"Content-Type: application/json",
		"Accept: application/json",
	];
	if (!config.api_key.is_empty()) :
		headers.append("Authorization: Bearer %s" % [config.api_key]);
	return headers;

func generate_context_request(context : AgentContext) -> Dictionary:
	var _req : Dictionary = _generate_request(
		context.config,
		_generate_messages(context.config.system_prompt, context.get_request_messages()),
		_generate_tools(context)
	);
	return _req;

func generate_compression_request(
	config : AgentConfig,
	existing_summary : String,
	messages : Array[AgentMessage]
) -> Dictionary:
	var compression_config : AgentConfig = config.duplicate(true) as AgentConfig;
	compression_config.stream = false;
	compression_config.n = 1;
	compression_config.system_prompt = "";

	var user_message := AgentConversationMessage.new()
	user_message.role = AgentMessage.Role.USER
	user_message.content = SUMMARY_USER_PROMPT % [
		existing_summary if (!existing_summary.is_empty()) else "(none)",
		_format_messages(messages)
	];

	var assistant_prefix := AgentConversationMessage.new();
	assistant_prefix.role = AgentMessage.Role.ASSISTANT;
	assistant_prefix.content = "";

	return _generate_request(
		compression_config,
		_generate_messages(SUMMARY_SYSTEM_PROMPT, [user_message, assistant_prefix]),
		[]
	);

func estimate_message_tokens(_config : AgentConfig, messages : Array[AgentMessage]) -> int:
	var tokens : int = 0;
	for message_dict : Dictionary in _generate_messages("", messages) :
		tokens += 4;
		tokens += _estimate_text_tokens(str(message_dict.get("role", "")));
		tokens += _estimate_text_tokens(str(message_dict.get("content", "")));
		if (message_dict.has("tool_call_id")) :
			tokens += _estimate_text_tokens(str(message_dict["tool_call_id"]));
		if (message_dict.has("tool_calls")) :
			tokens += _estimate_text_tokens(JSON.stringify(message_dict["tool_calls"]));
	return tokens;

func parse_error_body(body : String, http_status : int, source : String) -> AgentError:
	var body_text : String = body.strip_edges();
	var details : Dictionary = {};
	if (!body_text.is_empty()) :
		var json : JSON = JSON.new();
		if (json.parse(body_text) == OK && typeof(json.data) == TYPE_DICTIONARY) :
			details = json.data;

	if (details.has("error")) :
		var error_data : Dictionary = details["error"] if typeof(details["error"]) == TYPE_DICTIONARY else { "message" : str(details["error"]) };
		return AgentError.new(
			str(error_data.get("message", "Agent request failed.")),
			details,
			http_status,
			str(error_data.get("code", "")),
			str(error_data.get("type", "")),
			str(error_data.get("param", "")),
			body,
			source
		);

	if (http_status >= 400) :
		return AgentError.new(
			body_text if !body_text.is_empty() else "Agent request failed.",
			details,
			http_status,
			"",
			"",
			"",
			body,
			source
		);
	return null;

func phrase_response(json : Dictionary) -> Array[AgentAssistantMessage]:
	var result : Array[AgentAssistantMessage] = [];
	if (json.has("error")) :
		push_warning("Agent API returned an error response: %s" % [JSON.stringify(json["error"])]);
		return result;
	if (!json.has("choices") || typeof(json["choices"]) != TYPE_ARRAY) :
		push_warning("Agent API response has no choices array.");
		return result;

	var choices : Array[Dictionary] = [];
	for choice_data : Variant in json["choices"] :
		if (typeof(choice_data) == TYPE_DICTIONARY) :
			choices.push_back(choice_data);
	choices.sort_custom(func(a : Dictionary, b : Dictionary) -> bool: return int(a.get("index", 0)) < int(b.get("index", 0)));

	for choice : Dictionary in choices :
		if (choice.has("message") && typeof(choice["message"]) == TYPE_DICTIONARY) :
			result.push_back(_phrase_message(choice["message"]));
	return result;

func update_stream(ms : AgentAssistantMessageStream, json : Dictionary) -> void:
	if (!json.has("choices") || typeof(json["choices"]) != TYPE_ARRAY) :
		return;

	for choice_data : Variant in json["choices"] :
		if (typeof(choice_data) != TYPE_DICTIONARY) :
			continue;
		var choice : Dictionary = choice_data;
		if (choice.has("finish_reason") && choice["finish_reason"] != null) :
			ms.cache["finish_reason"] = choice["finish_reason"];
		if (!choice.has("delta") || typeof(choice["delta"]) != TYPE_DICTIONARY) :
			continue;
		var delta : Dictionary = choice["delta"];
		if (delta.has("role") && typeof(delta["role"]) == TYPE_STRING) :
			ms.cache["role"] = delta["role"];
		if (delta.has("content") && typeof(delta["content"]) == TYPE_STRING) :
			ms.content += delta["content"];
		if (delta.has("reasoning_content") && typeof(delta["reasoning_content"]) == TYPE_STRING) :
			ms.reasoning += delta["reasoning_content"];
		elif (delta.has("reasoning") && typeof(delta["reasoning"]) == TYPE_STRING) :
			ms.reasoning += delta["reasoning"];
		if (delta.has("tool_calls") && typeof(delta["tool_calls"]) == TYPE_ARRAY) :
			_update_stream_tool_calls(ms, delta["tool_calls"]);

func process_stream(ms : AgentAssistantMessageStream) -> void:
	var tool_calls_cache : Dictionary = ms.cache.get("tool_calls", {});
	var indexes : Array = tool_calls_cache.keys();
	indexes.sort();

	for index : Variant in indexes :
		var tool_call_cache : Variant = tool_calls_cache[index];
		if (typeof(tool_call_cache) != TYPE_DICTIONARY) :
			continue;
		var tool_call_dict : Dictionary = tool_call_cache;
		var function_dict : Dictionary = _get_dictionary(tool_call_dict, "function");
		var tool_call : AgentToolCall = _parse_tool_call(
			tool_call_dict.get("id", ""),
			function_dict.get("name", ""),
			function_dict.get("arguments", "")
		) as AgentToolCall;
		if (tool_call != null && tool_call.is_valid()) :
			ms.tool_calls.push_back(tool_call);
	ms.close();

func _generate_request(config : AgentConfig, messages : Array[Dictionary], tools : Array = []) -> Dictionary:
	var request : Dictionary = {
		"model" : config.model,
		"messages" : messages,
	};
	if (config.stream) : request["stream"] = true;
	if (config.temperature != 1.0) : request["temperature"] = config.temperature;
	if (config.top_p < 1.0) : request["top_p"] = config.top_p;
	if (config.n > 1) : request["n"] = config.n;
	if (config.max_tokens > 0) : request["max_tokens"] = config.max_tokens;
	if (!config.stop.is_empty()) : request["stop"] = Array(config.stop);
	if (config.presence_penalty != 0.0) : request["presence_penalty"] = config.presence_penalty;
	if (config.frequency_penalty != 0.0) : request["frequency_penalty"] = config.frequency_penalty;
	if (!tools.is_empty()) :
		request["tools"] = tools;
		request["tool_choice"] = "auto";
	return request;

func _generate_messages(system_prompt : String, history_messages : Array) -> Array[Dictionary]:
	var result : Array[Dictionary] = [];
	if (!system_prompt.strip_edges().is_empty()) :
		result.push_back({ "role" : "system", "content" : system_prompt });

	var pending_tool_call_ids : Array[String] = [];
	for msg : AgentMessage in history_messages :
		var msg_dict : Dictionary = {};
		match (msg.role) :
			AgentMessage.Role.USER:
				if (!pending_tool_call_ids.is_empty()) :
					continue;
				msg_dict["role"] = "user";
				msg_dict["content"] = msg.content;
			AgentMessage.Role.SYSTEM:
				if (!pending_tool_call_ids.is_empty()) :
					continue;
				msg_dict["role"] = "system";
				msg_dict["content"] = msg.content;
			AgentMessage.Role.ASSISTANT:
				if (!pending_tool_call_ids.is_empty()) :
					continue;
				msg_dict["role"] = "assistant";
				msg_dict["content"] = msg.content;
				var assistant_msg : AgentAssistantMessage = msg as AgentAssistantMessage;
				if (assistant_msg != null && !assistant_msg.tool_calls.is_empty()) :
					msg_dict["tool_calls"] = [];
					for tool_call : AgentToolCall in assistant_msg.tool_calls :
						if (tool_call.is_valid()) :
							pending_tool_call_ids.push_back(tool_call.id);
							msg_dict["tool_calls"].push_back({
								"id" : tool_call.id,
								"type" : "function",
								"function" : {
									"name" : tool_call.name,
									"arguments" : JSON.stringify(tool_call.arguments),
								},
							});
			AgentMessage.Role.TOOL:
				var tool_msg : AgentToolCallMessage = msg as AgentToolCallMessage;
				if (tool_msg == null || tool_msg.tool_call_id.is_empty()) :
					continue;
				if (!pending_tool_call_ids.has(tool_msg.tool_call_id)) :
					continue;
				msg_dict["role"] = "tool";
				msg_dict["tool_call_id"] = tool_msg.tool_call_id;
				msg_dict["content"] = tool_msg.content;
				pending_tool_call_ids.erase(tool_msg.tool_call_id);
			_:
				continue;
		result.push_back(msg_dict);
	return result;

func _generate_tools(context : AgentContext) -> Array[Dictionary]:
	var result : Array[Dictionary] = [];
	if (context.tool_actuator == null) :
		return result;
	for tool_name : String in context.tool_actuator.tool_list.keys() :
		var tool : AgentTool = context.tool_actuator.tool_list[tool_name];
		if (tool == null || tool._get_name().is_empty()) :
			continue;
		result.push_back({
			"type" : "function",
			"function" : {
				"name" : tool._get_name(),
				"description" : tool._get_description(),
				"parameters" : {
					"type" : "object",
					"properties" : tool._get_properties(),
				},
			},
		});
	return result;

func _phrase_message(dict : Dictionary) -> AgentAssistantMessage:
	var msg : AgentAssistantMessage = AgentAssistantMessage.new();
	if (dict.has("content") && dict["content"] != null) : msg.content = str(dict["content"]);
	if (dict.has("reasoning_content") && typeof(dict["reasoning_content"]) == TYPE_STRING) : msg.reasoning = dict["reasoning_content"];
	elif (dict.has("reasoning") && typeof(dict["reasoning"]) == TYPE_STRING) : msg.reasoning = dict["reasoning"];
	if (dict.has("tool_calls") && typeof(dict["tool_calls"]) == TYPE_ARRAY) :
		for tool_call_data : Variant in dict["tool_calls"] :
			if (typeof(tool_call_data) != TYPE_DICTIONARY) : continue;
			var function_dict : Dictionary = _get_dictionary(tool_call_data, "function");
			var tool_call : AgentToolCall = _parse_tool_call(
				tool_call_data.get("id", ""),
				function_dict.get("name", ""),
				function_dict.get("arguments", "{}")
			) as AgentToolCall;
			if (tool_call != null && tool_call.is_valid()) : msg.tool_calls.push_back(tool_call);
	return msg;

func _serialize_tool_calls(tool_calls : Array[AgentToolCall]) -> Array[Dictionary]:
	var result : Array[Dictionary] = [];
	for tool_call : AgentToolCall in tool_calls :
		if (tool_call.is_valid()) :
			result.push_back({
				"id" : tool_call.id,
				"type" : "function",
				"function" : {
					"name" : tool_call.name,
					"arguments" : JSON.stringify(tool_call.arguments),
				},
			});
	return result;

func _update_stream_tool_calls(ms : AgentAssistantMessageStream, tool_calls_delta : Array) -> void:
	if (!ms.cache.has("tool_calls") || typeof(ms.cache["tool_calls"]) != TYPE_DICTIONARY) :
		ms.cache["tool_calls"] = {};
	var tool_calls_cache : Dictionary = ms.cache["tool_calls"];
	for tool_call_data : Variant in tool_calls_delta :
		if (typeof(tool_call_data) != TYPE_DICTIONARY) : continue;
		var tool_call_delta : Dictionary = tool_call_data;
		var index : int = int(tool_call_delta.get("index", 0));
		if (!tool_calls_cache.has(index) || typeof(tool_calls_cache[index]) != TYPE_DICTIONARY) :
			tool_calls_cache[index] = { "id" : "", "type" : "function", "function" : { "name" : "", "arguments" : "" } };
		var tool_call_cache : Dictionary = tool_calls_cache[index];
		if (tool_call_delta.has("id") && typeof(tool_call_delta["id"]) == TYPE_STRING) : tool_call_cache["id"] = tool_call_delta["id"];
		if (tool_call_delta.has("type") && typeof(tool_call_delta["type"]) == TYPE_STRING) : tool_call_cache["type"] = tool_call_delta["type"];
		if (tool_call_delta.has("function") && typeof(tool_call_delta["function"]) == TYPE_DICTIONARY) :
			var function_delta : Dictionary = tool_call_delta["function"];
			var function_cache : Dictionary = tool_call_cache["function"];
			if (function_delta.has("name") && typeof(function_delta["name"]) == TYPE_STRING && !function_delta["name"].is_empty()) : function_cache["name"] = function_delta["name"];
			if (function_delta.has("arguments") && typeof(function_delta["arguments"]) == TYPE_STRING) : function_cache["arguments"] = str(function_cache.get("arguments", "")) + function_delta["arguments"];

func _format_messages(messages : Array[AgentMessage]) -> String:
	var lines : PackedStringArray = [];
	for message : AgentMessage in messages : lines.push_back("%s: %s" % [_role_name(message), message.content]);
	return "\n".join(lines);

func _role_name(message : AgentMessage) -> String:
	match (message.role) :
		AgentMessage.Role.SYSTEM: return "system";
		AgentMessage.Role.USER: return "user";
		AgentMessage.Role.ASSISTANT: return "assistant";
		AgentMessage.Role.TOOL: return "tool";
		_: return "unknown";

func _parse_tool_call(id_value : Variant, name_value : Variant, arguments_value : Variant) -> Variant:
	var arguments_variant : Variant = _parse_function_arguments(arguments_value);
	if (typeof(arguments_variant) != TYPE_DICTIONARY) :
		return null;
	var tool_call_id : String = "" if id_value == null else str(id_value);
	var function_name : String = "" if name_value == null else str(name_value);
	return AgentToolCall.new(tool_call_id, function_name, arguments_variant);

func _parse_function_arguments(raw_arguments : Variant) -> Variant:
	if (typeof(raw_arguments) == TYPE_DICTIONARY) : return raw_arguments;
	if (typeof(raw_arguments) != TYPE_STRING || raw_arguments.is_empty()) : return {};
	var arguments_json : JSON = JSON.new();
	if (arguments_json.parse(raw_arguments) == OK && typeof(arguments_json.data) == TYPE_DICTIONARY) : return arguments_json.data;
	push_warning("Tool call arguments are not a valid JSON object: %s" % [raw_arguments]);
	return null;

func _get_dictionary(source : Dictionary, key : String) -> Dictionary:
	if (source.has(key) && typeof(source[key]) == TYPE_DICTIONARY) : return source[key];
	return {};

## 估计Toeken，很原始
func _estimate_text_tokens(text: String) -> int:
	const ASCII_PER_TOKEN : int = 3.5;
	var ascii_run : int = 0;
	var tokens : int = 0;

	for i in range(text.length()):
		var code : int = text.unicode_at(i);
		
		if (code < 128) :
			ascii_run += 1;
			continue;
		
		if (ascii_run > 0):
			tokens += int(ceil(float(ascii_run) / ASCII_PER_TOKEN));
			ascii_run = 0;
		
		if (code <= 32):
			continue;
		
		var is_cjk := (
			(code >= 0x3400 && code <= 0x4DBF)
			|| (code >= 0x4E00 && code <= 0x9FFF)
			|| (code >= 0xF900 && code <= 0xFAFF)
			|| (code >= 0x20000 && code <= 0x2EBEF)
			|| (code >= 0x30000 && code <= 0x323AF)
		);
		
		var is_emoji := (
			(code >= 0x1F600 && code <= 0x1F64F)
			|| (code >= 0x1F300 && code <= 0x1F5FF)
			|| (code >= 0x1F680 && code <= 0x1F6FF)
			|| (code >= 0x1F900 && code <= 0x1F9FF)
			|| (code >= 0x1FA00 && code <= 0x1FA6F)
			|| (code >= 0x1FA70 && code <= 0x1FAFF)
			|| (code >= 0x2600 && code <= 0x26FF)
			|| (code >= 0x2700 && code <= 0x27BF)
		);

		if (is_cjk):
			tokens += 1;
		elif (is_emoji):
			tokens += 2;
		else:
			tokens += 1;
	
	if (ascii_run > 0):
		tokens += int(ceil(float(ascii_run) / ASCII_PER_TOKEN));
	return tokens;
