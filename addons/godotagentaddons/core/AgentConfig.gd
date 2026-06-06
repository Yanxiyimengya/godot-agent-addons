class_name AgentConfig;
extends Resource;

@export var base_url : String = "";
@export var api_key : String = "";
@export var system_prompt : String = "";

@export_category("Model")
@export var model : String = "";
@export var stream : bool = false;
@export var temperature : float = 1.0;
@export var top_p : float = 1.0;
@export var n : int = 1;
@export var max_tokens : int = 0;
@export var stop : PackedStringArray = [];
@export var presence_penalty : float = 0.0;
@export var frequency_penalty : float = 0.0;

@export_category("Network")
@export var connect_timeout_seconds : float = 15.0;
@export var request_timeout_seconds : float = 60.0;
@export var body_idle_timeout_seconds : float = 30.0;
@export var body_total_timeout_seconds : float = 120.0;
@export var stream_idle_timeout_seconds : float = 30.0;
@export var stream_total_timeout_seconds : float = 300.0;

@export_category("Tools")
@export var max_tool_rounds : int = 8;

@export_category("Compression")
@export var enable_compression : bool = true;
@export var max_recent_messages : int = 2;
@export var compression_token_threshold : int = 300;
