# 校外培训机构综合管理平台（SaaS）建设方案（Java + 美观 Web UI）

## 1. 平台定位

面向校外培训机构的 SaaS 教学管理系统，支持：

- 多机构（总部/分校）
- 多角色（超管、机构管理员、教务、教师、学生/家长、财务）
- 选课排课
- 作业管理
- 成绩管理
- 收费与对账管理

## 2. 推荐技术栈（稳定优先）

### 后端（Java）

- JDK 21（LTS）
- Spring Boot 3.3+
- Spring Security + JWT + RBAC（角色权限控制）
- MyBatis-Plus（或 JPA，建议统一）
- Redis（缓存/会话/限流）
- PostgreSQL 16（主库）
- Flyway（数据库版本管理）
- MinIO（作业附件、导出文件）

### 前端（好看、企业级）

- Vue 3 + TypeScript + Vite
- Ant Design Vue（后台管理风格成熟）
- ECharts（数据看板）
- Pinia + Vue Router
- Axios + OpenAPI 代码生成

### 运维部署（Debian 12）

- Docker + Docker Compose（首选）
- Nginx（静态资源 + 反向代理 + HTTPS）
- Prometheus + Grafana（监控）
- Loki + Promtail（日志聚合，可选）

## 3. 核心模块设计

1. **组织与机构中心**
   - 多租户：tenant_id 数据隔离
   - 机构层级：总部/校区
2. **用户与权限中心**
   - RBAC：菜单、按钮、数据权限
   - 登录方式：账号密码 + 短信（可选）
3. **教学教务中心**
   - 课程、班级、排课、教师分配、教室管理
   - 报班/选课（支持试听、候补）
4. **作业与成绩中心**
   - 作业模板、布置、提交、批改
   - 成绩录入、成长报告、学情统计
5. **收费财务中心**
   - 订单、收款、退款、欠费
   - 课时包、优惠券、发票（可扩展）
6. **通知与消息中心**
   - 站内信、短信、微信公众号（可扩展）
7. **报表中心**
   - 招生转化、出勤率、续费率、教师绩效

## 4. 建议数据库关键表

- tenant（租户）
- org_campus（校区）
- user / role / permission / user_role
- course / class / class_schedule
- enrollment（报名）
- homework / homework_submit
- exam / score
- order / payment / refund
- attendance
- audit_log

> 每张业务表统一包含：`id`、`tenant_id`、`created_at`、`updated_at`、`created_by`、`deleted`

## 5. 可靠性与安全要求

- 多租户强隔离：所有查询必须带 `tenant_id`
- 接口幂等：支付、退费、导入操作增加幂等键
- 审计日志：关键操作可追溯
- 数据备份：每日全量 + 每小时增量
- 安全基线：HTTPS、密码加盐、SQL 注入防护、限流、防暴力破解

## 6. 迭代路线（建议 3 个阶段）

### 阶段 1（6~8 周）MVP

- 机构、用户、角色、课程、班级、报名、收费、基础报表

### 阶段 2（4~6 周）教学增强

- 作业、成绩、学情看板、家长端消息通知

### 阶段 3（4~6 周）经营增强

- 续费预测、渠道统计、绩效看板、开放 API

## 7. Debian 12 部署建议（生产）

1. 使用 Docker Compose 部署 `postgres/redis/minio/backend/frontend/nginx`
2. 后端通过环境变量配置数据库、Redis、JWT 密钥
3. Nginx 配置 HTTPS 与 gzip，前后端同域反代避免跨域
4. 使用 systemd 托管 docker compose 服务，开机自启
5. 结合 UFW 只开放 80/443/22 端口

## 8. 你可以立刻开工的最小可交付物

- 后端：
  - 登录鉴权
  - 租户/机构/用户/角色
  - 课程/班级/报名
  - 收费订单
- 前端：
  - 登录页 + 控制台
  - 机构管理、学员管理、课程管理、收费管理

---

如果你愿意，我下一步可以直接给你：

1. **可运行的 Spring Boot + Vue3 项目骨架目录**
2. **核心数据库 SQL（首版）**
3. **Debian 12 一键部署脚本（Docker Compose）**

