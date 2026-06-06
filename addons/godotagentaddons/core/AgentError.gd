class_name AgentError;
extends RefCounted;

var message : String = "";
var details : Dictionary = {};
var http_status : int = 0;
var code : String = "";
var type : String = "";
var param : String = "";
var raw_body : String = "";
var source : String = "";

func _init(
	_message : String = "",
	_details : Dictionary = {},
	_http_status : int = 0,
	_code : String = "",
	_type : String = "",
	_param : String = "",
	_raw_body : String = "",
	_source : String = ""
) -> void:
	message = _message;
	details = _details.duplicate(true);
	http_status = _http_status;
	code = _code;
	type = _type;
	param = _param;
	raw_body = _raw_body;
	source = _source;

func _to_string() -> String:
	var prefix : String = source;
	if (http_status > 0) :
		prefix += " " if !prefix.is_empty() else "";
		prefix += "HTTP %s" % [http_status];
	if (!code.is_empty()) :
		prefix += " " if !prefix.is_empty() else "";
		prefix += "code %s" % [code];
	return message if prefix.is_empty() else "%s: %s" % [prefix, message];
