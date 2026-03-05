# 校外培训机构综合管理平台（Debian 12 可用 + Web UI）

这是一个可直接运行的 **SaaS 教学管理系统 MVP**，支持：

- 多角色
- 多机构
- 选课管理
- 作业管理
- 成绩管理
- 收费管理
- 可视化 Web 管理后台（浏览器全流程操作）

## 技术栈

- Python 3（标准库，无第三方依赖）
- SQLite（本地数据库）
- 原生 HTML/CSS/JS 单页 Web UI

## Debian 12 快速启动

```bash
python3 app.py
```

服务启动后：

- Web UI：`http://127.0.0.1:8000/`
- 健康检查：`http://127.0.0.1:8000/health`

## Web UI 功能

打开浏览器后可直接：

- 新增并查看机构
- 新增并查看多角色用户
- 新增并查看课程
- 新增并查看选课记录
- 新增并查看作业
- 新增并查看成绩
- 新增并查看收费记录
- 查询机构营收报表

## API 概览

- `GET /health`
- `POST/GET /api/organizations`
- `POST/GET /api/users`
- `POST/GET /api/courses`
- `POST/GET /api/enrollments`
- `POST/GET /api/homework`
- `POST/GET /api/grades`
- `POST/GET /api/payments`
- `GET /api/report/revenue?org_id=1`

## 一键冒烟测试

先启动服务，再执行：

```bash
./smoke_test.sh
```

成功输出：`smoke ok`

## 服务器远程部署（Debian 12）

程序默认监听 `0.0.0.0:8000`，可直接远程访问。

```bash
# 1) 上传代码到服务器后进入目录
cd /path/to/project

# 2) 启动（后台运行示例）
nohup python3 app.py > app.log 2>&1 &

# 3) 放行端口（按你的环境选择）
# ufw 示例：
sudo ufw allow 8000/tcp
```

然后通过 `http://<服务器IP>:8000/` 即可在浏览器远程操作。
