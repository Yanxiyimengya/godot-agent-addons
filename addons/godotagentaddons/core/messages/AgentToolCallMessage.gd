class_name AgentToolCallMessage;
extends AgentMessage;

var tool_call_id : String = "";

func _init(_tool_call_id : String = "", _content : String = "") -> void:
	self.role = Role.TOOL;
	self.tool_call_id = _tool_call_id;
	self.content = _content;
