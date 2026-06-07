class_name AgentContext;
extends Resource;

signal confirm_requested();
signal message_received(message : AgentMessage);
signal assistant_message_received(message : AgentMessage);
signal tool_call_processed(tool_call : AgentToolCall);

enum APIStandard
{
	OpenAI,
	Anthropic,
};

const HISTORY_SUMMARY_PREFIX : String = "[AgentContextSummary]\n";

@export var standard : APIStandard = APIStandard.OpenAI;
@export var config : AgentConfig = AgentConfig.new();

var api_adapter : AgentAPIAdapter;
var tool_actuator : AgentToolActuator;
@export
var history_messages : Array[AgentMessage] = [];
var pending_user_message : AgentConversationMessage = null;
var pending_confirm_message : Array[AgentAssistantMessage] = [];
var processing_tool_calls : Array[AgentToolCall] = [];

func _init(_standard : APIStandard = APIStandard.OpenAI) -> void:
	standard = _standard;
	create_api_adapter();
	create_tool_actuator();

func create_api_adapter() -> void:
	if (api_adapter != null):
		return;
	api_adapter = AgentAPIAdapter.new();
	match (standard) :
		APIStandard.OpenAI:
			api_adapter.sdk = OpenAIChatSDK.new();
		APIStandard.Anthropic:
			pass;

func create_tool_actuator() -> void:
	if (tool_actuator == null):
		tool_actuator = AgentToolActuator.new();

func clear_context() -> void:
	history_messages.clear();
	pending_user_message = null;
	pending_confirm_message.clear();
	processing_tool_calls.clear();

func append_message(message : AgentMessage, emit_received : bool = true) -> void:
	if (message == null) :
		return;
	history_messages.push_back(message);
	if (!emit_received) :
		return;
	message_received.emit(message);
	if (message.role == AgentMessage.Role.ASSISTANT) :
		assistant_message_received.emit(message);

func begin_pending_user_message(message : AgentConversationMessage, emit_received : bool = true) -> void:
	if (message == null) :
		return;
	message.role = AgentMessage.Role.USER;
	pending_user_message = message;
	if (emit_received) :
		message_received.emit(message);

func commit_pending_user_message(emit_received : bool = false) -> void:
	if (pending_user_message == null) :
		return;
	var message : AgentConversationMessage = pending_user_message;
	pending_user_message = null;
	if (!history_messages.has(message)) :
		append_message(message, emit_received);

func discard_pending_user_message() -> void:
	pending_user_message = null;

func get_request_messages() -> Array[AgentMessage]:
	var messages : Array[AgentMessage] = [];
	for message : AgentMessage in history_messages :
		messages.push_back(message);
	if (pending_user_message != null) :
		messages.push_back(pending_user_message);
	return messages;

func has_unanswered_tool_calls() -> bool:
	return !_get_unanswered_tool_call_ids().is_empty();

func create_message_stream() -> AgentAssistantMessageStream:
	var message_stream : AgentAssistantMessageStream = AgentAssistantMessageStream.new();
	return message_stream;

func compress_history(request_body : Callable) -> void:
	if (!config.enable_compression) :
		return;
	if (has_unanswered_tool_calls()) :
		return;
	var max_recent_messages : int = max(0, config.max_recent_messages);
	var recent_start : int = _adjust_recent_start(max(history_messages.size() - max_recent_messages, 0));
	if (recent_start <= 0) :
		return;

	var messages_to_summarize : Array[AgentMessage] = [];
	var recent_messages : Array[AgentMessage] = [];
	for index : int in range(history_messages.size()) :
		var message : AgentMessage = history_messages[index];
		if (_is_history_summary_message(message)) :
			continue;
		if (index < recent_start) :
			messages_to_summarize.push_back(message);
		else :
			recent_messages.push_back(message);
	if (messages_to_summarize.is_empty()) :
		return;
	if (api_adapter.estimate_message_tokens(config, messages_to_summarize) <= max(0, config.compression_token_threshold)) :
		return;

	var compression_request : Dictionary = api_adapter.generate_compression_request(
		config,
		_get_history_summary_content(),
		messages_to_summarize
	);
	var response_body : String = await request_body.call(compression_request, "Agent summary");
	if (response_body.is_empty()) :
		return;
	var summary_list : Array[AgentAssistantMessage] = api_adapter.phrase_response_body(response_body);
	if (!summary_list.is_empty() && !summary_list[0].content.strip_edges().is_empty()) :
		_replace_history_with_summary(summary_list[0].content, recent_messages);

func generate_request_body() -> Dictionary:
	return api_adapter.generate_context_request(self);

func process_response(body : String) -> Variant:
	if (!pending_confirm_message.is_empty()) :
		confirm_message(0);
	var message_list : Array[AgentAssistantMessage] = api_adapter.phrase_response_body(body);
	if (message_list.is_empty()) :
		return null;
	commit_pending_user_message(false);
	if (message_list.size() > 1) :
		pending_confirm_message = message_list;
		confirm_requested.emit();
	else :
		_commit_assistant_message(message_list[0]);
	return message_list[0];

func update_message_stream(ms : AgentAssistantMessageStream, json : Dictionary) -> void:
	api_adapter.update_message_stream(ms, json);

func close_message_stream(message_stream : AgentAssistantMessageStream) -> void:
	if (message_stream == null || !message_stream.streaming) :
		return;
	if (message_stream.cache.get("error", false)) :
		message_stream.close();
		return;
	api_adapter.close_message_stream(message_stream);
	commit_pending_user_message(false);
	_commit_assistant_message(message_stream, false);

func cancel_message_stream(message_stream : AgentAssistantMessageStream) -> void:
	if (message_stream != null && message_stream.streaming) :
		message_stream.close();

func confirm_message(index : int) -> void:
	if (pending_confirm_message.size() > index) :
		_commit_assistant_message(pending_confirm_message[index]);
		pending_confirm_message.clear();

func process_tool_calls(message : AgentAssistantMessage) -> void:
	if (message == null || message.tool_calls.is_empty()) :
		return;
	var pending_tool_calls : Array[AgentToolCall] = [];
	for pending_tool_call : AgentToolCall in message.tool_calls :
		if (!processing_tool_calls.has(pending_tool_call)) :
			processing_tool_calls.push_back(pending_tool_call);
			pending_tool_calls.push_back(pending_tool_call);

	for tool_call : AgentToolCall in pending_tool_calls :
		var result : Variant = await tool_actuator.call_tool(tool_call.name, tool_call.arguments);
		_insert_tool_message_after_assistant(
			message,
			AgentToolCallMessage.new(tool_call.id, _tool_result_to_content(result))
		);
		tool_call_processed.emit(tool_call);
		processing_tool_calls.erase(tool_call);

func process_unanswered_tool_calls() -> void:
	for message : AgentMessage in history_messages.duplicate() :
		var assistant_message : AgentAssistantMessage = message as AgentAssistantMessage;
		if (assistant_message == null || assistant_message.tool_calls.is_empty()) :
			continue;
		for tool_call : AgentToolCall in _get_missing_tool_calls(assistant_message) :
			var result : Variant = await tool_actuator.call_tool(tool_call.name, tool_call.arguments);
			_insert_tool_message_after_assistant(
				assistant_message,
				AgentToolCallMessage.new(tool_call.id, _tool_result_to_content(result))
			);
			tool_call_processed.emit(tool_call);

func _is_history_summary_message(message : AgentMessage) -> bool:
	return (
		message != null && \
		message.role == AgentMessage.Role.SYSTEM && \
		message.content.begins_with(HISTORY_SUMMARY_PREFIX)
		);

func _get_history_summary_content() -> String:
	for message : AgentMessage in history_messages :
		if (_is_history_summary_message(message)) :
			return message.content.substr(HISTORY_SUMMARY_PREFIX.length()).strip_edges();
	return "";

func _replace_history_with_summary(summary : String, recent_messages : Array[AgentMessage]) -> void:
	history_messages.clear();
	var summary_content : String = summary.strip_edges();
	if (!summary_content.is_empty()) :
		var summary_message : AgentConversationMessage = AgentConversationMessage.new();
		summary_message.role = AgentMessage.Role.SYSTEM;
		summary_message.content = HISTORY_SUMMARY_PREFIX + summary_content;
		history_messages.push_back(summary_message);
	for message : AgentMessage in recent_messages :
		if (!_is_history_summary_message(message)) :
			history_messages.push_back(message);

func _adjust_recent_start(recent_start: int) -> int:
	while (
		recent_start > 0 && recent_start < history_messages.size() \
		&& history_messages[recent_start].role == AgentMessage.Role.TOOL
		):
		recent_start -= 1;
	while (
		recent_start > 0 && recent_start < history_messages.size() \
		&& _assistant_message_has_tool_calls(history_messages[recent_start - 1])
		):
		recent_start -= 1;
	return recent_start;

func _commit_assistant_message(message : AgentAssistantMessage, emit_received : bool = true) -> void:
	if (message == null) :
		return;
	if (!history_messages.has(message)) :
		append_message(message, emit_received);
	elif (emit_received) :
		assistant_message_received.emit(message);

func _assistant_message_has_tool_calls(message : AgentMessage) -> bool:
	var assistant_message : AgentAssistantMessage = message as AgentAssistantMessage;
	return assistant_message != null && !assistant_message.tool_calls.is_empty();

func _get_unanswered_tool_call_ids() -> Array[String]:
	var pending_ids : Array[String] = [];
	for message : AgentMessage in history_messages :
		var assistant_message : AgentAssistantMessage = message as AgentAssistantMessage;
		if (assistant_message != null) :
			for tool_call : AgentToolCall in _get_missing_tool_calls(assistant_message) :
				pending_ids.push_back(tool_call.id);
	return pending_ids;

func _get_missing_tool_calls(assistant_message : AgentAssistantMessage) -> Array[AgentToolCall]:
	var missing : Array[AgentToolCall] = [];
	if (assistant_message == null || assistant_message.tool_calls.is_empty()) :
		return missing;

	var answered_ids : Dictionary = {};
	var assistant_index : int = history_messages.find(assistant_message);
	if (assistant_index >= 0) :
		var index : int = assistant_index + 1;
		while (index < history_messages.size()) :
			var tool_message : AgentToolCallMessage = history_messages[index] as AgentToolCallMessage;
			if (tool_message == null) :
				break;
			answered_ids[tool_message.tool_call_id] = true;
			index += 1;

	for tool_call : AgentToolCall in assistant_message.tool_calls :
		if (tool_call != null && tool_call.is_valid() && !answered_ids.has(tool_call.id)) :
			missing.push_back(tool_call);
	return missing;

func _insert_tool_message_after_assistant(assistant_message : AgentAssistantMessage, tool_message : AgentToolCallMessage) -> void:
	if (assistant_message == null || tool_message == null) :
		return;
	var assistant_index : int = history_messages.find(assistant_message);
	if (assistant_index < 0) :
		append_message(tool_message);
		return;

	var insert_index : int = assistant_index + 1;
	while (insert_index < history_messages.size() && history_messages[insert_index].role == AgentMessage.Role.TOOL) :
		insert_index += 1;
	history_messages.insert(insert_index, tool_message);
	message_received.emit(tool_message);

func _tool_result_to_content(result : Variant) -> String:
	match (typeof(result)) :
		TYPE_STRING:
			return result;
		TYPE_NIL:
			return JSON.stringify({ "result" : null });
		TYPE_DICTIONARY, TYPE_ARRAY, TYPE_BOOL, TYPE_INT, TYPE_FLOAT:
			return JSON.stringify(result);
		_:
			return JSON.stringify({ "result" : str(result) });
