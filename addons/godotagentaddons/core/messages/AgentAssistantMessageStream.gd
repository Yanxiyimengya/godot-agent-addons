class_name AgentAssistantMessageStream;
extends AgentAssistantMessage;

signal stream_updated();

var cache : Dictionary = {};
var streaming : bool = true;

var _content_cursor : int = 0;
var _reasoning_cursor : int = 0;

func read_content_delta() -> String:
	var delta : String = content.substr(_content_cursor);
	_content_cursor = content.length();
	return delta;

func read_reasoning_delta() -> String:
	var delta : String = reasoning.substr(_reasoning_cursor);
	_reasoning_cursor = reasoning.length();
	return delta;

func rewind_content_delta() -> void:
	_content_cursor = 0;

func rewind_reasoning_delta() -> void:
	_reasoning_cursor = 0;

func open() -> void:
	cache.clear();
	streaming = true;

func close() -> void:
	if (!streaming) :
		return;
	cache.clear();
	streaming = false;
	stream_updated.emit();
