# 外部资源

本仓库不上传图片、音乐、原始音频、原作摘录、完整检索资料、模型或训练数据。当前没有可公开下载的完整资源包；请仅使用自己有权使用且与版本匹配的文件。资源清单只记录路径、大小和 SHA-256，不会下载或授权这些文件。

`resources/manifest.json` 列出游戏媒体与剧情资源的恢复路径。将文件恢复到清单中的相对路径后执行：

```powershell
.\runtime\python\Scripts\python.exe scripts/check/assets.py --hash
```

游戏媒体放在 `game/ArcueidStage/assets/` 的对应子目录。原作公园剧情数据另行放在 `game/ArcueidStage/data/park_sequence.json`，不能用空白 JSON 冒充完整剧情。资源路径映射中已经移除开发电脑来源路径。

可选角色知识卡放在 `core/arcueid_core/knowledge/`，本地检索索引放在 `corpus/stage_index/`。缺少知识卡或索引时，相关角色知识／证据检索能力会降级；图片、音乐和剧情资源缺失则会被 Start 的预检查提示。

模型权重、共享底模、参考音频和 WSL 环境不属于上述游戏媒体清单，见 [语音说明](VOICE.md)。不要把个人配置、密钥、存档、日志或训练集放进资源提交。
