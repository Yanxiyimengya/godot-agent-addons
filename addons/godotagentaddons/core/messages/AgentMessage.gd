class_name AgentMessage;
extends Resource;

## 会话消息角色
enum Role 
{
	UNKNOWN,
	SYSTEM,
	USER,
	ASSISTANT,
	TOOL,
};

## 消息内容
@export
var content : String = "";

## 获取消息角色
@export
var role : Role = Role.UNKNOWN;

func _to_string() -> String:
	return "[AgentMessage]" + content;
