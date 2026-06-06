class_name AgentClient;
extends Node;

signal request_started();
signal request_finished();
signal request_failed(error : AgentError);
signal message_received(message : AgentMessage);
signal message_stream_started(message_stream : AgentAssistantMessageStream);
signal message_stream_updated(message_stream : AgentAssistantMessageStream);
signal tool_call_processed(tool_call : AgentToolCall);

@export var context : AgentContext;

var _is_requesting : bool = false;
var _bound_context : AgentContext = null;

func send_message(content : String) -> void:
	if (context == null) :
		_emit_error(AgentError.new("AgentClient has no AgentContext.", {}, 0, "missing_context", "client", "", "", "Agent"));
		return;
	if (content.is_empty()) :
		return;
	if (_is_requesting) :
		_emit_error(AgentError.new("AgentClient is already processing a request.", {}, 0, "request_in_progress", "client", "", "", "Agent"));
		return;

	_begin_request();
	_send_message_async.call_deferred(content);

func request_agent() -> void:
	if (context == null) :
		_emit_error(AgentError.new("AgentClient has no AgentContext.", {}, 0, "missing_context", "client", "", "", "Agent"));
		return;
	if (_is_requesting) :
		_emit_error(AgentError.new("AgentClient is already processing a request.", {}, 0, "request_in_progress", "client", "", "", "Agent"));
		return;
	_begin_request();
	_request_agent_async.call_deferred();

func _send_message_async(content : String) -> void:
	await context.process_unanswered_tool_calls();
	await context.compress_history(Callable(self, "request_body"));
	var user_msg : AgentConversationMessage = AgentConversationMessage.new();
	user_msg.role = AgentMessage.Role.USER;
	user_msg.content = content;
	context.begin_pending_user_message(user_msg);
	await _request_agent_internal();
	if (context.pending_user_message == user_msg) :
		context.discard_pending_user_message();
	_finish_request();

func _request_agent_async() -> void:
	await _request_agent_internal();
	_finish_request();

func _begin_request() -> void:
	_is_requesting = true;
	request_started.emit();
	_bind_context_signals();

func _request_agent_internal() -> void:
	await context.process_unanswered_tool_calls();

	if (context.config.stream) :
		var message_stream : AgentAssistantMessageStream = context.create_message_stream();
		await _request_stream_until_done(message_stream);
		return;

	await _request_body_until_done();

func _request_body_until_done() -> Variant:
	var tool_rounds : int = 0;
	while (true) :
		var response_body : String = await request_body(context.generate_request_body(), "Agent");
		if (response_body.is_empty()) :
			return null;
		var reply : Variant = context.process_response(response_body);
		var assistant_message : AgentAssistantMessage = reply as AgentAssistantMessage;
		if (assistant_message == null || assistant_message.tool_calls.is_empty()) :
			return reply;
		if (tool_rounds >= _max_tool_rounds()) :
			_emit_error(AgentError.new("Maximum tool call rounds exceeded.", { "max_tool_rounds" : _max_tool_rounds() }, 0, "max_tool_rounds_exceeded", "tool", "", "", "Agent"));
			return reply;
		await context.process_tool_calls(assistant_message);
		tool_rounds += 1;
	return null;

func _request_stream_until_done(output_stream : AgentAssistantMessageStream) -> void:
	var tool_rounds : int = 0;
	while (output_stream != null && output_stream.streaming) :
		var http_client : HTTPClient = await _request_stream(context.generate_request_body(), "Agent");
		if (http_client == null) :
			context.cancel_message_stream(output_stream);
			return;

		var round_stream : AgentAssistantMessageStream = AgentAssistantMessageStream.new();
		var stream_ok : bool = await _read_stream_body(http_client, round_stream, output_stream);
		http_client.close();
		if (!stream_ok || round_stream.cache.get("error", false)) :
			context.cancel_message_stream(round_stream);
			context.cancel_message_stream(output_stream);
			return;

		context.close_message_stream(round_stream);
		if (round_stream.tool_calls.is_empty()) :
			output_stream.close();
			return;
		if (tool_rounds >= _max_tool_rounds()) :
			_emit_error(AgentError.new("Maximum tool call rounds exceeded.", { "max_tool_rounds" : _max_tool_rounds() }, 0, "max_tool_rounds_exceeded", "tool", "", "", "Agent"));
			output_stream.close();
			return;
		await context.process_tool_calls(round_stream);
		tool_rounds += 1;

func _finish_request() -> void:
	if (!_is_requesting) :
		return;
	_is_requesting = false;
	request_finished.emit();

func _bind_context_signals() -> void:
	if (context == null) :
		return;
	if (_bound_context != null && _bound_context != context) :
		if (_bound_context.message_received.is_connected(_on_context_message_received)) :
			_bound_context.message_received.disconnect(_on_context_message_received);
		if (_bound_context.tool_call_processed.is_connected(_on_context_tool_call_processed)) :
			_bound_context.tool_call_processed.disconnect(_on_context_tool_call_processed);
	if (!context.message_received.is_connected(_on_context_message_received)) :
		context.message_received.connect(_on_context_message_received);
	if (!context.tool_call_processed.is_connected(_on_context_tool_call_processed)) :
		context.tool_call_processed.connect(_on_context_tool_call_processed);
	_bound_context = context;

func _on_context_message_received(message : AgentMessage) -> void:
	message_received.emit(message);
	var message_stream : AgentAssistantMessageStream = message as AgentAssistantMessageStream;
	if (message_stream != null) :
		message_stream_started.emit(message_stream);
		var stream_updated_callback : Callable = _on_message_stream_updated.bind(message_stream);
		if (!message_stream.stream_updated.is_connected(stream_updated_callback)) :
			message_stream.stream_updated.connect(stream_updated_callback);

func _on_message_stream_updated(message_stream : AgentAssistantMessageStream) -> void:
	message_stream_updated.emit(message_stream);

func _on_context_tool_call_processed(tool_call : AgentToolCall) -> void:
	tool_call_processed.emit(tool_call);

func request_body(request_body_dict : Dictionary, warning_prefix : String = "Agent") -> String:
	if (context == null) :
		_emit_error(AgentError.new("AgentClient has no AgentContext.", {}, 0, "missing_context", "client", "", "", warning_prefix));
		return "";
	var http_client : HTTPClient = await _request_stream(request_body_dict, warning_prefix);
	if (http_client == null) :
		return "";
	var response_code : int = http_client.get_response_code();
	var body : String = await _read_body(http_client, warning_prefix);
	http_client.close();
	if (body.strip_edges().is_empty()) :
		_emit_error(AgentError.new("Response body is empty.", {}, response_code, "empty_body", "transport", "", body, warning_prefix));
		return "";
	if (_emit_response_error(body, response_code, warning_prefix)) :
		return "";
	return body;

func _request_stream(request_body_dict : Dictionary, warning_prefix : String) -> HTTPClient:
	var url : String = context.api_adapter.generate_request_url(context.config);
	var parsed_url : Dictionary = _parse_url(url);
	if (parsed_url.is_empty()) :
		_emit_error(AgentError.new("Request URL is invalid.", { "url" : url }, 0, "invalid_url", "transport", "", "", warning_prefix));
		return null;

	var http_client : HTTPClient = HTTPClient.new();
	var tls_options : TLSOptions = TLSOptions.client() if parsed_url["tls"] else null;
	var connect_error : Error = http_client.connect_to_host(parsed_url["host"], parsed_url["port"], tls_options);
	if (connect_error != OK) :
		_emit_error(AgentError.new("Connect failed.", { "error" : connect_error }, 0, str(connect_error), "transport", "", "", warning_prefix));
		return null;

	var connect_start_msec : int = Time.get_ticks_msec();
	while (http_client.get_status() == HTTPClient.STATUS_CONNECTING || http_client.get_status() == HTTPClient.STATUS_RESOLVING) :
		http_client.poll();
		if (_is_timeout(connect_start_msec, context.config.connect_timeout_seconds)) :
			_emit_timeout("Connect", context.config.connect_timeout_seconds, warning_prefix, { "url" : url });
			http_client.close();
			return null;
		await get_tree().process_frame;
	if (http_client.get_status() != HTTPClient.STATUS_CONNECTED) :
		_emit_error(AgentError.new("Connection failed.", { "status" : http_client.get_status() }, 0, str(http_client.get_status()), "transport", "", "", warning_prefix));
		http_client.close();
		return null;

	var request_error : Error = http_client.request(
		HTTPClient.METHOD_POST,
		parsed_url["path"],
		context.api_adapter.generate_header(context.config),
		JSON.stringify(request_body_dict)
	);
	if (request_error != OK) :
		_emit_error(AgentError.new("Request failed.", { "error" : request_error }, 0, str(request_error), "transport", "", "", warning_prefix));
		http_client.close();
		return null;

	var request_start_msec : int = Time.get_ticks_msec();
	while (http_client.get_status() == HTTPClient.STATUS_REQUESTING) :
		http_client.poll();
		if (_is_timeout(request_start_msec, context.config.request_timeout_seconds)) :
			_emit_timeout("Request", context.config.request_timeout_seconds, warning_prefix, { "url" : url });
			http_client.close();
			return null;
		await get_tree().process_frame;
	if (!http_client.has_response()) :
		_emit_error(AgentError.new("Response is empty.", {}, 0, "empty_response", "transport", "", "", warning_prefix));
		http_client.close();
		return null;

	var response_code : int = http_client.get_response_code();
	if (response_code < 200 || response_code >= 300) :
		var error_body : String = await _read_body(http_client, warning_prefix);
		_emit_response_error(error_body, response_code, warning_prefix);
		http_client.close();
		return null;
	return http_client;

func _read_body(http_client : HTTPClient, warning_prefix : String = "Agent") -> String:
	var body : PackedByteArray = PackedByteArray();
	var read_start_msec : int = Time.get_ticks_msec();
	var last_chunk_msec : int = read_start_msec;
	while (http_client.get_status() == HTTPClient.STATUS_BODY) :
		http_client.poll();
		var chunk : PackedByteArray = http_client.read_response_body_chunk();
		if (!chunk.is_empty()) :
			body.append_array(chunk);
			last_chunk_msec = Time.get_ticks_msec();
		if (_is_timeout(read_start_msec, context.config.body_total_timeout_seconds)) :
			_emit_timeout("Response body", context.config.body_total_timeout_seconds, warning_prefix);
			return "";
		if (_is_timeout(last_chunk_msec, context.config.body_idle_timeout_seconds)) :
			_emit_timeout("Response body idle", context.config.body_idle_timeout_seconds, warning_prefix);
			return "";
		await get_tree().process_frame;
	return body.get_string_from_utf8();

func _read_stream_body(
	http_client : HTTPClient,
	message_stream : AgentAssistantMessageStream,
	output_stream : AgentAssistantMessageStream = null
) -> bool:
	var read_start_msec : int = Time.get_ticks_msec();
	var last_chunk_msec : int = read_start_msec;
	while (http_client.get_status() == HTTPClient.STATUS_BODY) :
		http_client.poll();
		var chunk : PackedByteArray = http_client.read_response_body_chunk();
		if (!chunk.is_empty()) :
			last_chunk_msec = Time.get_ticks_msec();
			var previous_content_length : int = message_stream.content.length();
			_process_streaming_response(chunk.get_string_from_utf8(), message_stream);
			_mirror_stream_delta(message_stream, output_stream, previous_content_length);
			if (message_stream.cache.get("done", false)) :
				return !message_stream.cache.get("error", false);
		if (_is_timeout(read_start_msec, context.config.stream_total_timeout_seconds)) :
			_emit_timeout("Agent stream", context.config.stream_total_timeout_seconds, "Agent");
			message_stream.cache["error"] = true;
			return false;
		if (_is_timeout(last_chunk_msec, context.config.stream_idle_timeout_seconds)) :
			_emit_timeout("Agent stream idle", context.config.stream_idle_timeout_seconds, "Agent");
			message_stream.cache["error"] = true;
			return false;
		await get_tree().process_frame;
	_flush_sse_buffer(message_stream, output_stream);
	return !message_stream.cache.get("error", false);

func _process_streaming_response(body : String, message_stream : AgentAssistantMessageStream) -> void:
	if (message_stream == null || body.is_empty()) :
		return;
	var buffer : String = str(message_stream.cache.get("sse_buffer", "")) + body;
	message_stream.cache["sse_buffer"] = _process_sse_buffer(message_stream, buffer);

func _process_sse_buffer(message_stream : AgentAssistantMessageStream, buffer : String) -> String:
	var normalized : String = buffer.replace("\r\n", "\n").replace("\r", "\n");
	var events : Array = normalized.split("\n\n", false);
	if (!normalized.ends_with("\n\n")) :
		if (events.is_empty()) :
			return normalized;
		buffer = events.pop_back();
	else :
		buffer = "";
	for event : String in events :
		_process_sse_event(message_stream, event);
	return buffer;

func _process_sse_event(message_stream : AgentAssistantMessageStream, event : String) -> void:
	var data_lines : PackedStringArray = [];
	for raw_line : String in event.split("\n", false) :
		var line : String = raw_line.strip_edges();
		if (line.begins_with("data:")) :
			data_lines.push_back(line.substr(5).strip_edges());
	if (data_lines.is_empty()) :
		return;

	var data : String = "\n".join(data_lines).strip_edges();
	if (data == "[DONE]") :
		message_stream.cache["done"] = true;
		return;

	var json : JSON = JSON.new();
	if (json.parse(data) != OK || typeof(json.data) != TYPE_DICTIONARY) :
		_emit_error(AgentError.new("Parse agent stream JSON failed: %s" % [json.get_error_message()], { "data" : data }, 0, "invalid_stream_json", "transport", "", data, "Agent"));
		message_stream.cache["error"] = true;
		message_stream.cache["done"] = true;
		return;
	if (_emit_response_error(data, 0, "Agent")) :
		message_stream.cache["error"] = true;
		message_stream.cache["done"] = true;
		return;
	context.update_message_stream(message_stream, json.data);

func _flush_sse_buffer(message_stream : AgentAssistantMessageStream, output_stream : AgentAssistantMessageStream = null) -> void:
	if (message_stream == null) :
		return;
	var buffer : String = str(message_stream.cache.get("sse_buffer", "")).strip_edges();
	if (buffer.is_empty()) :
		return;
	var previous_content_length : int = message_stream.content.length();
	message_stream.cache["sse_buffer"] = "";
	_process_sse_event(message_stream, buffer);
	_mirror_stream_delta(message_stream, output_stream, previous_content_length);

func _mirror_stream_delta(
	source_stream : AgentAssistantMessageStream,
	output_stream : AgentAssistantMessageStream,
	previous_content_length : int
) -> void:
	if (source_stream == null || output_stream == null || !output_stream.streaming) :
		return;
	if (source_stream.content.length() <= previous_content_length) :
		return;
	output_stream.content += source_stream.content.substr(previous_content_length);
	output_stream.stream_updated.emit();

func _emit_response_error(body : String, http_status : int, source : String) -> bool:
	var error : AgentError = null;
	if (context != null && context.api_adapter != null) :
		error = context.api_adapter.parse_error_body(body, http_status, source);
	if (error == null && http_status >= 400) :
		error = AgentError.new("Agent request failed.", {}, http_status, "", "http", "", body, source);
	if (error == null) :
		return false;
	_emit_error(error);
	return true;

func _emit_error(error : AgentError) -> void:
	if (error == null) :
		return;
	request_failed.emit(error);
	push_warning(str(error));

func _emit_timeout(phase : String, timeout_seconds : float, source : String, details : Dictionary = {}) -> void:
	_emit_error(AgentError.new("%s timed out after %.2f seconds." % [phase, timeout_seconds], details, 0, "timeout", "transport", "", "", source));

func _is_timeout(start_msec : int, timeout_seconds : float) -> bool:
	if (timeout_seconds <= 0.0) :
		return false;
	return Time.get_ticks_msec() - start_msec >= int(timeout_seconds * 1000.0);

func _max_tool_rounds() -> int:
	return max(0, context.config.max_tool_rounds);

func _parse_url(url : String) -> Dictionary:
	var regex : RegEx = RegEx.new();
	if (regex.compile("^(https?)://([^/:?#]+)(?::([0-9]+))?([^?#]*)?(?:\\?([^#]*))?") != OK) :
		return {};
	var match_result : RegExMatch = regex.search(url);
	if (match_result == null) :
		return {};

	var scheme : String = match_result.get_string(1).to_lower();
	var port_text : String = match_result.get_string(3);
	var path : String = match_result.get_string(4);
	var query : String = match_result.get_string(5);
	if (path.is_empty()) :
		path = "/";
	if (!query.is_empty()) :
		path += "?" + query;
	return {
		"host" : match_result.get_string(2),
		"port" : int(port_text) if !port_text.is_empty() else (443 if scheme == "https" else 80),
		"tls" : scheme == "https",
		"path" : path,
	};
