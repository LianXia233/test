# 校外培训机构综合管理平台（SaaS）建设方案（Java + 美观 Web UI）

## 1. 平台定位

面向培训机构的 SaaS 教学管理系统，支持：

- 多角色（超管、机构管理员、教务、教师、学生/家长、财务）
- 多机构（总部/分校）
- 选课排课、作业、成绩、收费管理

## 2. 推荐技术栈（生产稳定优先）

### 后端（Java）

- Java 17 LTS（Debian 12 默认 apt 友好）
- Spring Boot 3.3+
- Spring Security + JWT + RBAC（角色权限）
- MyBatis-Plus（或 JPA，建议统一）
- Redis（缓存/会话/限流）
- PostgreSQL 15（Debian 12 默认仓库）
- Flyway（数据库迁移）
- 对象存储（S3 兼容，可接 MinIO/云厂商 OSS/COS）

### 前端（好看、企业级）

- Vue 3 + TypeScript + Vite
- Ant Design Vue（后台 UI 成熟）
- ECharts（数据看板）
- Pinia + Vue Router
- Axios + OpenAPI 代码生成

### 部署（Debian 12 原生部署）

- **不使用 Docker / Docker Compose**
- apt 安装依赖（JDK/PostgreSQL/Redis/Nginx/Node.js）
- systemd 托管 Java 服务（开机自启）
- Nginx 反向代理 + HTTPS
- Certbot 自动续签证书

## 3. 核心模块设计

1. **组织与机构中心**
   - 多租户：`tenant_id` 数据隔离
   - 机构层级：总部/校区
2. **用户与权限中心**
   - RBAC：菜单、按钮、数据权限
   - 登录方式：账号密码（短信可选）
3. **教学教务中心**
   - 课程、班级、排课、教师分配、教室管理
   - 报班/选课（试听、候补）
4. **作业与成绩中心**
   - 作业模板、布置、提交、批改
   - 成绩录入、成长报告、学情统计
5. **收费财务中心**
   - 订单、收款、退款、欠费
   - 课时包、优惠券、发票（可扩展）
6. **通知与消息中心**
   - 站内信、短信、公众号（可扩展）
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

> 业务表建议统一包含：`id`、`tenant_id`、`created_at`、`updated_at`、`created_by`、`deleted`

## 5. 可靠性与安全要求

- 多租户强隔离：所有查询必须带 `tenant_id`
- 接口幂等：支付、退费、导入等关键操作引入幂等键
- 审计日志：关键操作可追溯
- 数据备份：每日全量 + 每小时增量（PostgreSQL）
- 安全基线：HTTPS、密码加盐、注入防护、限流、防暴力破解

## 6. 迭代路线（建议）

### 阶段 1（6~8 周）MVP

- 机构、用户、角色、课程、班级、报名、收费、基础报表

### 阶段 2（4~6 周）教学增强

- 作业、成绩、学情看板、家长端消息通知

### 阶段 3（4~6 周）经营增强

- 续费预测、渠道统计、绩效看板、开放 API

## 7. Debian 12 直接部署（不使用 Docker）

1. apt 安装：`openjdk-17-jdk`、`postgresql`、`redis-server`、`nginx`、`nodejs`、`npm`
2. PostgreSQL 创建业务库与账号，配置本机访问与强密码
3. Redis 启用密码与 `supervised systemd`
4. 前端 `npm run build`，产物放到 `/var/www/edu-admin`
5. 后端 JAR 放 `/opt/edu-platform/app.jar`，用 systemd 管理
6. Nginx 同域反代（`/api -> 127.0.0.1:8080`）避免跨域
7. Certbot 签发 HTTPS 证书

详细命令见：`docs/debian12-direct-deploy.md`

## 8. 最小可交付物（可立即开工）

- 后端：登录鉴权、租户/机构/用户/角色、课程/班级/报名、收费订单
- 前端：登录页 + 控制台、机构管理、学员管理、课程管理、收费管理
