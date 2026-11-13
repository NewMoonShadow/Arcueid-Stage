"""Local model configuration. Never return keys or upstream error bodies."""
from __future__ import annotations

import json
import os
from dataclasses import replace
from urllib.parse import urlsplit

import httpx
from fastapi import HTTPException, Request


def public_settings(settings):
    return {"provider": settings.provider, "base_url": settings.base_url,
            "model": settings.model, "has_api_key": bool(settings.api_key),
            "ciel_override": any(os.environ.get(name) for name in
                ("ARCUEID_CIEL_API_KEY", "ARCUEID_CIEL_MODEL", "ARCUEID_CIEL_BASE_URL", "ARCUEID_CIEL_PROVIDER"))}


async def candidate(request: Request, settings):
    # Native Godot requests have no Origin. Reject browser-origin writes.
    if request.headers.get("origin") or request.headers.get("sec-fetch-site"):
        raise HTTPException(403, "请从游戏内设置窗口配置 API。")
    try:
        body = await request.json()
        if not isinstance(body, dict):
            raise ValueError
        values = {}
        for name in ("provider", "base_url", "model", "api_key"):
            value = body.get(name, "")
            if not isinstance(value, str) or len(value) > (4096 if name == "api_key" else 512):
                raise ValueError
            values[name] = value.strip()
        if not values["api_key"]:
            values["api_key"] = settings.api_key
        values["provider"] = values["provider"] or "openai-compatible"
        url = urlsplit(values["base_url"])
        if url.scheme not in {"http", "https"} or not url.hostname or url.username or url.password or url.query or url.fragment:
            raise ValueError
        if url.scheme == "http" and url.hostname not in {"localhost", "127.0.0.1", "::1"}:
            raise HTTPException(400, "远程服务地址请使用 https://；http:// 仅用于本机模型。")
        if any(ord(c) < 32 for value in values.values() for c in value):
            raise ValueError
        values["base_url"] = values["base_url"].rstrip("/")
        if values["base_url"].endswith("/chat/completions"):
            raise HTTPException(400, "请填写 Base URL，不要包含 /chat/completions。")
        if not values["model"]:
            raise HTTPException(400, "请填写平台提供的模型 ID。")
        if not values["api_key"]:
            raise HTTPException(400, "请填写 API Key；本机无鉴权服务可填写 local 占位。")
        return replace(settings, **values)
    except (ValueError, TypeError):
        raise HTTPException(400, "配置格式不正确，请检查地址、模型名称和密钥。") from None


def register_model_api(app, core):
    @app.get("/api/v2/settings/model")
    async def read():
        return public_settings(core.settings)

    @app.put("/api/v2/settings/model")
    async def save(request: Request):
        updated = await candidate(request, core.settings)
        path = updated.data_dir / "model_api.json"
        temporary = path.with_suffix(".tmp")
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            # Exclusive access is serialized by this synchronous atomic write.
            temporary.write_text(json.dumps({name: getattr(updated, name) for name in
                ("provider", "base_url", "model", "api_key")}, ensure_ascii=False), encoding="utf-8")
            os.replace(temporary, path)
        except OSError:
            temporary.unlink(missing_ok=True)
            raise HTTPException(500, "无法保存本机配置，请检查数据目录的写入权限。") from None
        core.settings = updated
        return {"ok": True, **public_settings(updated)}

    @app.post("/api/v2/settings/model/test")
    async def test(request: Request):
        updated = await candidate(request, core.settings)
        try:
            # A short completion checks the actual protocol, model, and credentials.
            async with httpx.AsyncClient(timeout=6.0, follow_redirects=False) as client:
                response = await client.post(updated.base_url + "/chat/completions",
                    headers={"Authorization": "Bearer " + updated.api_key},
                    json={"model": updated.model, "messages": [{"role": "user", "content": "Reply OK."}],
                          "max_tokens": 16, "stream": False})
            errors = {401: "密钥无效或已过期，请重新复制 API Key。", 403: "账号没有访问权限，请检查模型授权或地区限制。",
                      402: "余额不足，请检查平台账户余额。", 404: "地址或模型不存在，请检查 Base URL 和模型 ID。",
                      429: "请求限流或额度不足，请检查平台额度并稍后重试。"}
            if not response.is_success:
                return {"ok": False, "message": errors.get(response.status_code, "服务拒绝了请求，请检查模型是否支持 Chat Completions 和 max_tokens。")}
            data = response.json()
            if not isinstance(data, dict) or not data.get("choices"):
                return {"ok": False, "message": "服务已连接，但返回格式不符合 Chat Completions 协议。"}
            return {"ok": True, "message": "连接成功，模型已接受测试请求。点击「保存 API 配置」后用于新请求。"}
        except httpx.TimeoutException:
            return {"ok": False, "message": "连接超时，请检查网络、地址，或稍后重试。"}
        except (httpx.HTTPError, ValueError):
            return {"ok": False, "message": "连接失败，请检查网络、证书与服务地址。"}
