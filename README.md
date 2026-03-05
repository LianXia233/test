# 校外培训机构综合管理平台（Debian 12 可用版）

这是一个可直接运行的最小可用后端（MVP 原型），定位为：

> 面向培训机构的 SaaS 教学管理系统，支持多角色、多机构、选课、作业、成绩、收费管理。

## 技术选型

- Python 3（标准库，无第三方依赖）
- SQLite（本地文件数据库）
- HTTP JSON API

> 适配默认 Debian 12 环境，安装 `python3` 与 `curl` 即可运行。

## 快速启动（Debian 12）

```bash
python3 app.py
```

启动后服务地址：`http://127.0.0.1:8000`

## 核心接口

- `GET /health`：健康检查
- `POST/GET /api/organizations`：机构管理
- `POST/GET /api/users`：多角色用户
- `POST/GET /api/courses`：课程管理
- `POST/GET /api/enrollments`：选课管理
- `POST/GET /api/homework`：作业管理
- `POST/GET /api/grades`：成绩管理
- `POST/GET /api/payments`：收费管理
- `GET /api/report/revenue?org_id=1`：营收汇总

## 一键冒烟测试

先启动服务，再执行：

```bash
./smoke_test.sh
```

成功后输出：`smoke ok`

## 示例请求

```bash
curl -X POST http://127.0.0.1:8000/api/organizations \
  -H 'Content-Type: application/json' \
  -d '{"name":"示例机构"}'
```

