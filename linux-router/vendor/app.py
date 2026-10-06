from __future__ import annotations

from datetime import timedelta

from flask import Flask

from router_panel.core import ensure_auth_config, ensure_secret_key
from router_panel.web import register_routes


app = Flask(__name__)
app.config["PERMANENT_SESSION_LIFETIME"] = timedelta(hours=12)
# 【会话安全】显式固化 cookie 属性，避免依赖框架默认值随版本漂移：
#   HTTPONLY  —— JS 读不到 session cookie，降低 XSS 后的会话劫持收益
#   SAMESITE  —— Lax：跨站请求不携带会话 cookie（CSRF token 仍是主要防线，此处为第二层）
#   SECURE    —— False：管理面目前是局域网 HTTP（http://192.168.88.1）。
#                若后续启用 HTTPS/反向代理 TLS，必须改为 True，否则 cookie 会明文外泄。
app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    SESSION_COOKIE_SECURE=False,
    SESSION_COOKIE_NAME="router_panel_session",
)

ensure_auth_config()
app.secret_key = ensure_secret_key()
register_routes(app)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
