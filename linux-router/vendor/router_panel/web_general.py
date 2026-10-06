from __future__ import annotations

from flask import flash, redirect, render_template, request, session, url_for
from werkzeug.security import check_password_hash, generate_password_hash

from .agent_client import AgentError, query_agent, submit_operation
from .core import (
    load_auth_config,
    load_network_config,
    normalize_lan_network,
    save_auth_config,
    save_network_config,
)
from .security import audit, lockout_remaining, register_failure, register_success


def register_general_routes(app, login_required, is_async_request) -> None:
    def queued_response(operation, message, redirect_endpoint):
        if is_async_request():
            return {
                "ok": True,
                "pending": True,
                "message": message,
                "operation_id": operation["id"],
                "operation_url": url_for("operation_status", operation_id=operation["id"]),
            }, 202
        flash(message, "success")
        return redirect(url_for(redirect_endpoint))

    def dependency_fragment(status: dict) -> dict[str, str]:
        return {"dependencies": render_template("partials/dependency_groups.html", dependencies=status)}

    def dependency_status_or_empty() -> dict:
        try:
            return query_agent("dependency_status")
        except AgentError:
            return {"groups": {}, "summary": {"ok": 0, "warning": 0, "error": 1}}

    @app.route("/")
    def index():
        if session.get("logged_in"):
            return redirect(url_for("system_info"))
        return redirect(url_for("login"))


    @app.route("/login", methods=["GET", "POST"])
    def login():
        error = ""
        if request.method == "POST":
            # 【登录限流】先检查来源是否处于锁定窗口内；锁定期间直接拒绝，
            # 不做密码校验也不触碰存储，避免成为 CPU/IO 放大面。
            client_key = request.remote_addr or "unknown"
            wait_seconds = lockout_remaining(client_key)
            if wait_seconds > 0:
                remaining = int(wait_seconds) + 1
                audit("login.locked", ip=client_key, retry_after=remaining)
                return render_template(
                    "login.html",
                    error=f"登录失败次数过多，请等待 {remaining} 秒后重试",
                ), 429

            password = request.form.get("password", "")
            auth = load_auth_config()
            username = auth.get("username", "admin")

            if check_password_hash(auth.get("password_hash", ""), password):
                register_success(client_key)
                audit("login.success", ip=client_key, user=username)
                session.clear()
                session.permanent = True
                session["logged_in"] = True
                session["username"] = username
                return redirect(url_for("system_info"))

            delay = register_failure(client_key)
            # 统一错误文案，不区分"用户不存在/口令错误"，避免用户名枚举
            audit("login.failure", ip=client_key, lockout=int(delay))
            error = "用户名或密码错误"
            if delay > 0:
                error = f"用户名或密码错误（失败次数过多，已锁定 {int(delay)} 秒）"

        return render_template("login.html", error=error)


    @app.route("/logout", methods=["POST"])
    @login_required
    def logout():
        session.clear()
        return redirect(url_for("login"))


    @app.route("/settings")
    @login_required
    def system_settings():
        return render_template("settings.html", network=load_network_config())


    @app.route("/dependencies")
    @login_required
    def dependencies_page():
        try:
            status = query_agent("dependency_status")
        except AgentError as exc:
            flash(str(exc), "error")
            status = {"groups": {}, "summary": {"ok": 0, "warning": 0, "error": 1}}
        return render_template(
            "dependencies.html",
            dependencies=status,
        )


    @app.route("/dependencies/fix", methods=["POST"])
    @login_required
    def dependency_fix():
        action = request.form.get("action", "").strip()
        try:
            operation = submit_operation(
                "dependency_fix",
                {"action": action},
                scope="dependencies",
            )
        except AgentError as exc:
            if is_async_request():
                return {
                    "ok": False,
                    "pending": False,
                    "message": str(exc),
                    "fragments": dependency_fragment(dependency_status_or_empty()),
                }, 503
            flash(str(exc), "error")
            return redirect(url_for("dependencies_page"))
        if is_async_request():
            response, status_code = queued_response(
                operation, "依赖修复已加入队列", "dependencies_page"
            )
            response["fragments"] = dependency_fragment(dependency_status_or_empty())
            return response, status_code
        return queued_response(operation, "依赖修复已加入队列", "dependencies_page")


    @app.route("/settings/password", methods=["POST"])
    @login_required
    def update_password():
        current_password = request.form.get("current_password", "")
        new_password = request.form.get("new_password", "")
        confirm_password = request.form.get("confirm_password", "")
        auth = load_auth_config()

        if not check_password_hash(auth.get("password_hash", ""), current_password):
            flash("当前密码不正确", "error")
        elif len(new_password) < 4:
            flash("新密码至少需要 4 个字符", "error")
        elif new_password != confirm_password:
            flash("两次输入的新密码不一致", "error")
        else:
            auth["password_hash"] = generate_password_hash(new_password)
            save_auth_config(auth)
            flash("密码已更新", "success")
        return redirect(url_for("system_settings"))


    @app.route("/settings/lan", methods=["POST"])
    @login_required
    def update_lan_network():
        network, error = normalize_lan_network(request.form.get("lan_network", ""))
        if error or network is None:
            flash(error or "LAN 网段无效", "error")
        else:
            save_network_config(network)
            flash(f"LAN 网段已保存为 {network}，下次开启热点时生效", "success")
        return redirect(url_for("system_settings"))


    @app.route("/settings/reboot", methods=["POST"])
    @login_required
    def reboot_system():
        try:
            operation = submit_operation("system_reboot", {}, scope="system")
        except AgentError as exc:
            flash(str(exc), "error")
            return redirect(url_for("system_settings"))
        return queued_response(operation, "设备重启已加入队列", "system_settings")


    @app.route("/system")
    @login_required
    def system_info():
        try:
            info = query_agent("system_info")
        except AgentError as exc:
            flash(str(exc), "error")
            info = {}
        return render_template("system.html", info=info)


    @app.route("/wired")
    @login_required
    def wired_network():
        try:
            wired = query_agent("wired_status")
        except AgentError as exc:
            wired = {"devices": [], "errors": [str(exc)]}
        return render_template("wired.html", wired=wired)


    @app.route("/healthz")
    def healthz():
        try:
            return query_agent("health")
        except AgentError as exc:
            return {"status": "error", "message": str(exc)}, 503
