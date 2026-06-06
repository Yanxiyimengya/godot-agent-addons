class_name AgentAssistantMessage;
extends AgentMessage;

var reasoning : String = "";
var tool_calls : Array[AgentToolCall] = [];

func _init(_content : String = "") -> void:
	role = Role.ASSISTANT;
	content = _content;
