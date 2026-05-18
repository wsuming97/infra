# Infra — 基础设施统一编排

CPA (CLI Proxy API) + New API + PostgreSQL + Redis 的统一部署方案，为 `gpt_image_playground`、`gpt_image_free_monitor` 等业务项目提供 API 代理服务。

---

## 📐 架构

```
┌─────────────────────────────────────────────────────┐
│                    Infra (本项目)                     │
│                                                      │
│  ┌──────────────┐    ┌──────────────┐               │
│  │   CPA        │    │   New API    │               │
│  │   :8317      │    │   :3480      │               │
│  └──────┬───────┘    └──────┬───────┘               │
│         │                   │                        │
│  ┌──────▼───────────────────▼───────┐  ┌─────────┐ │
│  │       PostgreSQL 16              │  │  Redis   │ │
│  │  cliproxy 库  │  newapi 库       │  │  :6379   │ │
│  └──────────────────────────────────┘  └─────────┘ │
└─────────────────────────────────────────────────────┘
         ▲                    ▲
         │ --proxy            │
  ┌──────┴───────┐    ┌──────┴───────┐
  │  Playground  │    │   Monitor    │
  │  :8381       │    │   :8382      │
  └──────────────┘    └──────────────┘
```

## 🚀 部署

### 1. 配置环境变量

```bash
cp .env.example .env
# 编辑 .env，修改密码等配置
```

### 2. 启动服务

```bash
docker compose up -d
```

### 3. 验证

```bash
# CPA 管理页面
curl http://localhost:8317

# New API 状态检查
curl http://localhost:3480/api/status
```

### 4. 业务项目对接

```bash
# playground 部署时指向 CPA
cd /opt/gpt_image_playground
bash install.sh --proxy http://host.docker.internal:8317

# monitor 同理
cd /opt/gpt_image_free_monitor
bash install.sh --proxy http://host.docker.internal:8317
```

---

## 🔄 更新

```bash
docker compose pull        # 拉取最新镜像
docker compose up -d       # 重建变更的容器
```

## 🗑️ 卸载

```bash
docker compose down        # 停止并删除容器
# 如需清除数据：
# rm -rf pgdata cpa-data newapi-data newapi-logs
```

---

## 📁 目录结构

```
infra/
├── docker-compose.yml        # 主编排文件
├── .env.example              # 环境变量模板
├── .env                      # 实际配置（Git 忽略）
├── init-db/
│   └── 01-create-databases.sql  # PG 首次启动建库脚本
├── pgdata/                   # PostgreSQL 数据（Git 忽略）
├── cpa-data/                 # CPA 运行数据（Git 忽略）
├── newapi-data/              # New API 数据（Git 忽略）
└── newapi-logs/              # New API 日志（Git 忽略）
```

## 🔌 端口规划

| 服务 | 端口 | 说明 |
|------|------|------|
| CPA | 8317 | API 代理，业务项目通过 `--proxy` 指向此处 |
| New API | 3480 | 多渠道 Key 管理面板 |
| PostgreSQL | 内部 | 仅容器间通信，不对外暴露 |
| Redis | 内部 | 仅容器间通信，不对外暴露 |
