# Debian 12 部署指引（基础版）

## 1. 安装 Docker 与 Compose

```bash
sudo apt update
sudo apt install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo $VERSION_CODENAME) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

## 2. 启动基础中间件

```bash
docker compose up -d
```

## 3. 检查容器状态

```bash
docker compose ps
```

## 4. 生产环境建议

- 不要使用示例默认密码，改成强密码并放入 `.env`。
- PostgreSQL 建议开启自动备份与 WAL 归档。
- MinIO 建议分离对象存储磁盘，并配置生命周期策略。
- Nginx 配置 TLS 证书（Let's Encrypt）。
