class_name AgentToolCall;
extends RefCounted;

var id : String = "";
var name : String = "";
var arguments : Dictionary = {};

func _init(
	_id : String = "",
	_name : String = "",
	_arguments : Dictionary = {}
) -> void:
	id = _id;
	name = _name;
	arguments = _arguments;

## 检查当前是否为一个有效的 ToolCall
func is_valid() -> bool : 
	return !self.id.is_empty() && !self.name.is_empty()
