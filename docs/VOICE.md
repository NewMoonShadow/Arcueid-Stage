# 本地实时语音

完整语音链路为 Godot → Core → Proxy → 本机 GPT-SoVITS。Core／Proxy 使用 Windows Python 3.11；语音引擎使用独立 WSL Ubuntu 环境。默认只监听本机，不需要开放公网端口。

1. 使用 `scripts/setup/setup.ps1 -FetchVoiceEngine` 获取 `dependencies/gpt-sovits.lock.json` 固定的引擎代码。目标目录为 `runtime/gpt-sovits/`；已有目录时不会覆盖。
2. 按该版本官方引擎说明安装适合本机的 PyTorch／CUDA 依赖，独立环境放在 `runtime/voice-venv/`。现有验证环境为 Python 3.10.12，与 Core／Proxy 分开，不能混用两个环境。
3. 角色权重目录 `GPT_weights_v2Pro/` 和 `SoVITS_weights_v2Pro/` 放到引擎根目录。具体模型文件名见 `voice/profiles/voices.json`。共享底模放引擎的 `GPT_SoVITS/pretrained_models/`，包括匹配版本的中文 BERT、HuBERT 与 v2Pro 依赖。
4. 参考音频放 `models/references/arcueid.wav`、`neco_arc.wav` 和 `ciel.wav`。同时准备 `ciel.json`，其中 `text` 是参考音频对应日语原句，`boundary_policy` 为 `full_original_utterance`。不能任意替换参考音频并沿用不匹配的原句。
5. 手动复制 `voice/proxy/service/config.example.json` 为同目录的 `config.json` 并配置本机代理。执行 `runtime/python/Scripts/python.exe scripts/setup/prepare_voice_profiles.py` 生成本机推理 YAML，再运行 `Start.bat`。

角色端口为 9880／9881／9882，代理为 8766。三角色环境、底模、权重与参考文件没有包含在源码中；本公开仓库目前也没有发布这些附件。首次模型加载与推理可能较慢，不承诺未验证显卡或 CPU 的实时体验。

依赖装在其他位置时，可创建被忽略的 `runtime/paths.local.json`，覆盖 `engine`、`wsl_python`、`wsl_distribution`、`python`、`profiles`、`references` 这几个路径字段。相对路径均从仓库根目录解析；只存路径，不存密钥。默认值见 `scripts/common/paths.ps1`。
