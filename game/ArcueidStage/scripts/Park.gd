extends "res://scripts/Main.gd"


func _ensure_save() -> void:
	ApiClient.request_json(HTTPClient.METHOD_GET, "/api/v2/saves", {}, func(success: bool, saves) -> void:
		if success and saves is Array:
			for save in saves:
				if str(save.get("identity_mode", "")) == "shiki" and str(save.get("name", "")) != "教教我吧 · 爱尔奎特老师":
					_select_save(save, false)
					_connect_ready()
					return
		ApiClient.request_json(HTTPClient.METHOD_POST, "/api/v2/saves", {"name": "公园的十分钟", "identity_mode": "shiki", "user_name": ""}, func(created: bool, save) -> void:
			if created and save is Dictionary:
				_select_save(save, false)
				_connect_ready()
			else:
				status_label.text = "●　未连接到 Arcueid Core"
				_retry_ensure_save()
		)
	)


func _connect_ready() -> void:
	super._connect_ready()
	# Selecting the save also loads its story; wait before starting or resuming.
	var target_save_id := AppState.save_id
	while story_loading:
		await get_tree().process_frame
		if AppState.save_id != target_save_id:
			return
	if not _story_active():
		_start_story()
