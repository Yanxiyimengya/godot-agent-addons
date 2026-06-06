class_name AgentToolTest
extends AgentTool;

func _get_name() -> String :
	return "write_file";

func _get_description() -> String:
	return "写入文件";

func _get_properties() -> Dictionary:
	return {
		"file_path" : {
			"type": "string",
			"description": "读写文件的路径，基于Godot项目的`res://`目录,不需要添加res://前缀",
		},
		"content" : {
			"type": "string",
			"description": "写入的文件内容",
		},
	};

func _call(_args : Dictionary) -> Variant:
	var f : FileAccess = \
			FileAccess.open("res://" + _args["file_path"],FileAccess.WRITE);
	if (f):
		f.store_string(_args["content"]);
		return "ok";
	else : 
		return "can not open file %s" % ["res://" + _args["file_path"]];
