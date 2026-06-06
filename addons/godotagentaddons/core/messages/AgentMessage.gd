class_name AgentMessage;
extends RefCounted;

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
var content : String = "";

## 获取消息角色
var role : Role = Role.UNKNOWN;

func _to_string() -> String:
	return "[AgentMessage]" + content;
