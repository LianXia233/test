# Debian 12 直接部署指引（apt 安装依赖，不使用 Docker）

> 目标：纯 Debian 12 原生部署（systemd + nginx），不使用 Docker、Docker Compose、K8s。

## 1. 安装系统依赖（apt）

```bash
sudo apt update
sudo apt install -y openjdk-17-jdk postgresql redis-server nginx nodejs npm certbot python3-certbot-nginx ufw
```

可选（Node 版本太低时）：改用 NodeSource 安装 Node 20 LTS。

## 2. PostgreSQL 初始化

```bash
sudo -u postgres psql
```

在 `psql` 中执行：

```sql
CREATE USER edu WITH PASSWORD '请替换为强密码';
CREATE DATABASE edu_saas OWNER edu;
\q
```

配置本机密码访问（按实际版本调整路径）：

- 常见路径：`/etc/postgresql/15/main/pg_hba.conf`

确保存在：

```conf
host    all             all             127.0.0.1/32            scram-sha-256
```

重启数据库：

```bash
sudo systemctl restart postgresql
sudo systemctl enable postgresql
```

## 3. Redis 加固

编辑 `/etc/redis/redis.conf`：

- 设置 `requirepass` 为强密码
- 设置 `supervised systemd`

然后执行：

```bash
sudo systemctl restart redis-server
sudo systemctl enable redis-server
```

## 4. 部署后端（Spring Boot）

```bash
sudo mkdir -p /opt/edu-platform
sudo cp app.jar /opt/edu-platform/app.jar
sudo chown -R www-data:www-data /opt/edu-platform
```

创建 systemd 服务 `/etc/systemd/system/edu-platform.service`：

```ini
[Unit]
Description=Edu SaaS Platform Backend
After=network.target postgresql.service redis-server.service

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/edu-platform
Environment="SPRING_PROFILES_ACTIVE=prod"
Environment="DB_URL=jdbc:postgresql://127.0.0.1:5432/edu_saas"
Environment="DB_USER=edu"
Environment="DB_PASSWORD=请替换为强密码"
Environment="REDIS_HOST=127.0.0.1"
Environment="REDIS_PORT=6379"
Environment="REDIS_PASSWORD=请替换为强密码"
Environment="JWT_SECRET=请替换为高强度密钥"
ExecStart=/usr/bin/java -jar /opt/edu-platform/app.jar
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

启动服务：

```bash
sudo systemctl daemon-reload
sudo systemctl enable edu-platform
sudo systemctl restart edu-platform
sudo systemctl status edu-platform --no-pager
```

## 5. 部署前端（Vue3）

在前端项目目录执行：

```bash
npm ci
npm run build
sudo mkdir -p /var/www/edu-admin
sudo cp -r dist/* /var/www/edu-admin/
sudo chown -R www-data:www-data /var/www/edu-admin
```

## 6. Nginx 反向代理（同域）

创建 `/etc/nginx/sites-available/edu-platform.conf`：

```nginx
server {
    listen 80;
    server_name example.com;

    root /var/www/edu-admin;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:8080/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

启用配置并重载：

```bash
sudo ln -sf /etc/nginx/sites-available/edu-platform.conf /etc/nginx/sites-enabled/edu-platform.conf
sudo nginx -t
sudo systemctl reload nginx
sudo systemctl enable nginx
```

## 7. HTTPS 与防火墙

```bash
sudo certbot --nginx -d example.com
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'
sudo ufw --force enable
```

## 8. 对象存储（无 Docker 方案）

可选其一：

1. 使用云对象存储（阿里 OSS / 腾讯 COS / AWS S3）
2. 使用独立存储服务器部署 MinIO（与业务机分离）
3. 过渡方案：本地文件系统 + 定期备份（小规模）

## 9. 验证清单

```bash
java -version
psql --version
redis-server --version
nginx -v
systemctl is-active postgresql redis-server edu-platform nginx
curl -I http://127.0.0.1/api/health
```

## 10. 生产建议

- 配置 PostgreSQL 定时备份（`pg_dump` + 定时任务）
- 后端日志写入 journald 并配合 logrotate
- 敏感配置不要硬编码，建议放 `/etc/edu-platform/.env`
- 开启接口限流、登录失败锁定、审计日志
