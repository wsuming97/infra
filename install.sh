#!/bin/bash
# ============================================================
# Infra 基础设施 — 一键安装/更新/卸载脚本
#
# 统一部署 CPA + New API + PostgreSQL + Redis
#
# 用法：
#   git clone https://github.com/wsuming97/infra.git
#   cd infra && bash install.sh
#
#   bash install.sh --cpa-port 8317 --newapi-port 3480
#   bash install.sh --cpa-password mypass123
#   bash install.sh --proxy http://172.17.0.1:7890
#
# 更新与卸载：
#   bash install.sh --update
#   bash install.sh --uninstall
# ============================================================

set -euo pipefail

# ============================================================
# 全局配置
# ============================================================
REPO_URL_HTTPS="https://github.com/wsuming97/infra.git"
REPO_URL_SSH="git@github.com:wsuming97/infra.git"
INSTALL_DIR="/opt/infra"

# 默认端口
DEFAULT_CPA_PORT=8317
DEFAULT_NEWAPI_PORT=3480

# 默认密码（部署时建议修改）
DEFAULT_PG_PASSWORD="postgres123"
DEFAULT_CPA_DB_PASSWORD="cliproxy123"
DEFAULT_CPA_MGMT_PASSWORD="changeme"
DEFAULT_NEWAPI_DB_PASSWORD="newapi123"

# ============================================================
# 颜色与输出
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}>>> $1${NC}"; }
ok()    { echo -e "${GREEN}✅ $1${NC}"; }
warn()  { echo -e "${YELLOW}⚠️  $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; }
fatal() { error "$1"; exit 1; }

# ============================================================
# 帮助信息
# ============================================================
show_help() {
    cat << EOF
${BOLD}Infra 基础设施 一键部署脚本${NC}

${BOLD}用法:${NC}
  bash install.sh [选项]

${BOLD}选项:${NC}
  --cpa-port PORT         CPA 端口（默认 ${DEFAULT_CPA_PORT}）
  --newapi-port PORT      New API 端口（默认 ${DEFAULT_NEWAPI_PORT}）
  --cpa-password PASS     CPA 管理密码（默认 ${DEFAULT_CPA_MGMT_PASSWORD}）
  --pg-password PASS      PostgreSQL 超级用户密码
  --proxy URL             HTTP/HTTPS 代理（如 http://172.17.0.1:7890）
  --dir, -d DIR           自定义安装目录（默认 ${INSTALL_DIR}）
  --update, -u            更新到最新版本
  --uninstall, --remove   卸载
  -h, --help              显示此帮助

${BOLD}安装示例:${NC}
  git clone https://github.com/wsuming97/infra.git
  cd infra && bash install.sh
  bash install.sh --cpa-password my_secure_password
  bash install.sh --proxy http://172.17.0.1:7890

${BOLD}更新与卸载:${NC}
  cd ${INSTALL_DIR} && bash install.sh --update
  cd ${INSTALL_DIR} && bash install.sh --uninstall
EOF
}

# ============================================================
# 参数解析
# ============================================================
ACTION="install"
CPA_PORT=""
NEWAPI_PORT=""
CPA_MGMT_PASSWORD=""
PG_PASSWORD=""
HTTP_PROXY_URL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --update|-u)
            ACTION="update"
            shift
            ;;
        --uninstall|--remove)
            ACTION="uninstall"
            shift
            ;;
        --cpa-port)
            CPA_PORT="$2"
            shift 2
            ;;
        --newapi-port)
            NEWAPI_PORT="$2"
            shift 2
            ;;
        --cpa-password)
            CPA_MGMT_PASSWORD="$2"
            shift 2
            ;;
        --pg-password)
            PG_PASSWORD="$2"
            shift 2
            ;;
        --proxy)
            HTTP_PROXY_URL="$2"
            shift 2
            ;;
        --dir|-d)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            warn "未知参数: $1，忽略"
            shift
            ;;
    esac
done

# ============================================================
# 环境检查
# ============================================================
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        fatal "请使用 root 用户或 sudo 执行此脚本"
    fi
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        fatal "Docker 未安装。请先安装 Docker：https://docs.docker.com/engine/install/"
    fi

    if ! docker info &>/dev/null; then
        fatal "Docker 服务未启动，请执行: systemctl start docker"
    fi

    # 检查 docker compose
    if docker compose version &>/dev/null; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
    else
        fatal "Docker Compose 未安装。请安装 Docker Compose v2"
    fi

    ok "Docker 环境检查通过 ($(docker --version | head -1))"
}

check_git() {
    if ! command -v git &>/dev/null; then
        info "Git 未安装，正在自动安装..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq && apt-get install -y -qq git 2>/dev/null
        elif command -v yum &>/dev/null; then
            yum install -y -q git 2>/dev/null
        elif command -v apk &>/dev/null; then
            apk add --no-cache git 2>/dev/null
        else
            fatal "无法自动安装 Git，请手动安装"
        fi
        ok "Git 安装完成"
    fi
}

# ============================================================
# 检测是否在仓库目录内执行
# ============================================================
is_inside_repo() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -d "$script_dir/.git" ] && [ -f "$script_dir/docker-compose.yml" ]; then
        echo "$script_dir"
        return 0
    fi
    return 1
}

# ============================================================
# 从已有 .env 中读取配置（用于更新时保留配置）
# ============================================================
get_current_config() {
    local key="$1"
    local default="$2"
    if [ -f "$INSTALL_DIR/.env" ]; then
        local val
        val=$(grep -oP "^${key}=\K.*" "$INSTALL_DIR/.env" 2>/dev/null | head -1 || echo "")
        echo "${val:-$default}"
    else
        echo "$default"
    fi
}

# ============================================================
# 生成 .env 配置文件
# ============================================================
generate_env() {
    local cpa_port="$1"
    local newapi_port="$2"
    local pg_pass="$3"
    local cpa_mgmt_pass="$4"
    local proxy="$5"

    cat > "$INSTALL_DIR/.env" << ENV
# ============================================================
# Infra 基础设施配置（由 install.sh 自动生成）
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

# ── PostgreSQL 超级用户 ───────────────────────────────────
PG_SUPERUSER=postgres
PG_SUPERUSER_PASSWORD=${pg_pass}

# ── CPA 配置 ─────────────────────────────────────────────
CPA_PORT=${cpa_port}
CPA_MANAGEMENT_PASSWORD=${cpa_mgmt_pass}
CPA_DB_USER=cliproxy
CPA_DB_PASSWORD=${DEFAULT_CPA_DB_PASSWORD}
CPA_DB_NAME=cliproxy

# ── New API 配置 ──────────────────────────────────────────
NEWAPI_PORT=${newapi_port}
NEWAPI_DB_USER=newapi
NEWAPI_DB_PASSWORD=${DEFAULT_NEWAPI_DB_PASSWORD}
NEWAPI_DB_NAME=newapi

# ── 网络代理 ─────────────────────────────────────────────
HTTP_PROXY=${proxy}
HTTPS_PROXY=${proxy}
ENV

    ok ".env 配置文件已生成"
}

# ============================================================
# 工具函数
# ============================================================
get_server_ip() {
    local ip=""
    local ipv4_regex='[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'

    # 依次尝试外部服务获取公网 IPv4
    for url in ifconfig.me ip.sb icanhazip.com; do
        ip=$(curl -4 -s --max-time 3 "$url" 2>/dev/null | grep -Eo "$ipv4_regex" | head -1)
        [ -n "$ip" ] && echo "$ip" && return
    done

    # 回退到本机网卡 IPv4
    ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -Eo "$ipv4_regex" | head -1)
    [ -n "$ip" ] && echo "$ip" && return

    echo "your-server-ip"
}

# ============================================================
# 安装
# ============================================================
do_install() {
    info "开始安装 Infra 基础设施..."

    # 如果目标目录已存在且有 docker-compose.yml，提示用户
    if [ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/.env" ]; then
        warn "检测到已有安装 ($INSTALL_DIR)"
        echo -e "  如需更新，请使用: ${CYAN}cd $INSTALL_DIR && bash install.sh --update${NC}"
        echo -e "  如需重新安装，请先卸载: ${CYAN}cd $INSTALL_DIR && bash install.sh --uninstall${NC}"
        exit 1
    fi

    check_git

    # 检测是否在已克隆的仓库目录内执行
    local repo_dir
    if repo_dir=$(is_inside_repo); then
        info "检测到在仓库目录内执行: $repo_dir"
        if [ "$repo_dir" != "$INSTALL_DIR" ]; then
            info "复制到安装目录 ${INSTALL_DIR}..."
            cp -r "$repo_dir" "$INSTALL_DIR"
        fi
        ok "使用本地仓库"
    else
        info "克隆仓库到 ${INSTALL_DIR}..."
        if ! git clone "$REPO_URL_HTTPS" "$INSTALL_DIR" 2>/dev/null; then
            info "HTTPS 克隆失败，尝试 SSH..."
            if ! git clone "$REPO_URL_SSH" "$INSTALL_DIR" 2>/dev/null; then
                fatal "仓库克隆失败。请先手动克隆：\n  git clone $REPO_URL_HTTPS\n  cd infra && bash install.sh"
            fi
        fi
    fi

    # 确定配置
    local cpa_port="${CPA_PORT:-$DEFAULT_CPA_PORT}"
    local newapi_port="${NEWAPI_PORT:-$DEFAULT_NEWAPI_PORT}"
    local pg_pass="${PG_PASSWORD:-$DEFAULT_PG_PASSWORD}"
    local cpa_mgmt_pass="${CPA_MGMT_PASSWORD:-$DEFAULT_CPA_MGMT_PASSWORD}"
    local proxy="${HTTP_PROXY_URL:-}"

    # 生成 .env
    generate_env "$cpa_port" "$newapi_port" "$pg_pass" "$cpa_mgmt_pass" "$proxy"

    # 创建数据目录
    mkdir -p "$INSTALL_DIR"/{pgdata,cpa-data,newapi-data,newapi-logs}

    # 拉取镜像并启动
    info "拉取镜像并启动容器（首次拉取约 2-5 分钟）..."
    cd "$INSTALL_DIR"
    $COMPOSE_CMD pull
    $COMPOSE_CMD up -d

    # 等待服务健康
    info "等待服务启动..."
    sleep 10

    local server_ip
    server_ip=$(get_server_ip)

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    ok "安装完成！"
    echo ""
    echo -e "  ${BOLD}CPA 管理页面:${NC}     ${CYAN}http://${server_ip}:${cpa_port}${NC}"
    echo -e "  ${BOLD}New API 管理面板:${NC}  ${CYAN}http://${server_ip}:${newapi_port}${NC}"
    echo -e "  ${BOLD}CPA 管理密码:${NC}     ${CYAN}${cpa_mgmt_pass}${NC}"
    echo -e "  ${BOLD}安装目录:${NC}          ${CYAN}${INSTALL_DIR}${NC}"
    echo ""
    echo -e "  ${BOLD}业务项目对接:${NC}"
    echo -e "    cd /opt/gpt_image_playground && bash install.sh --proxy http://host.docker.internal:${cpa_port}"
    echo -e "    cd /opt/gpt_image_free_monitor && bash install.sh --proxy http://host.docker.internal:${cpa_port}"
    echo ""
    echo -e "  ${BOLD}更新命令:${NC} ${CYAN}cd ${INSTALL_DIR} && bash install.sh --update${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ============================================================
# 更新
# ============================================================
do_update() {
    info "开始更新 Infra 基础设施..."

    if [ ! -d "$INSTALL_DIR" ] || [ ! -f "$INSTALL_DIR/docker-compose.yml" ]; then
        fatal "未检测到安装目录 ($INSTALL_DIR)，请先安装"
    fi

    cd "$INSTALL_DIR"

    # 保存当前配置
    local current_cpa_port current_newapi_port current_pg_pass current_cpa_mgmt_pass current_proxy
    current_cpa_port=$(get_current_config "CPA_PORT" "$DEFAULT_CPA_PORT")
    current_newapi_port=$(get_current_config "NEWAPI_PORT" "$DEFAULT_NEWAPI_PORT")
    current_pg_pass=$(get_current_config "PG_SUPERUSER_PASSWORD" "$DEFAULT_PG_PASSWORD")
    current_cpa_mgmt_pass=$(get_current_config "CPA_MANAGEMENT_PASSWORD" "$DEFAULT_CPA_MGMT_PASSWORD")
    current_proxy=$(get_current_config "HTTP_PROXY" "")

    # 拉取最新代码
    local remote branch
    remote=$(git remote | head -1)
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "master")

    info "拉取最新代码 (remote: $remote, branch: $branch)..."
    git fetch "$remote"
    git reset --hard "$remote/$branch"

    # 恢复配置（命令行参数 > 已有配置 > 默认值）
    local cpa_port="${CPA_PORT:-$current_cpa_port}"
    local newapi_port="${NEWAPI_PORT:-$current_newapi_port}"
    local pg_pass="${PG_PASSWORD:-$current_pg_pass}"
    local cpa_mgmt_pass="${CPA_MGMT_PASSWORD:-$current_cpa_mgmt_pass}"
    local proxy="${HTTP_PROXY_URL:-$current_proxy}"

    generate_env "$cpa_port" "$newapi_port" "$pg_pass" "$cpa_mgmt_pass" "$proxy"

    # 如果 CPA 管理密码发生变更，清除缓存使新密码生效
    if [ -n "$CPA_MGMT_PASSWORD" ] && [ "$CPA_MGMT_PASSWORD" != "$current_cpa_mgmt_pass" ]; then
        warn "检测到 CPA 管理密码变更，清除密码缓存..."
        $COMPOSE_CMD stop cli-proxy-api 2>/dev/null || true
        rm -rf "$INSTALL_DIR/cpa-data/"*
        ok "CPA 密码缓存已清除"
    fi

    # 拉取最新镜像并重启
    info "拉取最新镜像并重启容器..."
    $COMPOSE_CMD pull
    $COMPOSE_CMD up -d --force-recreate

    local server_ip
    server_ip=$(get_server_ip)

    echo ""
    ok "更新完成！"
    echo -e "  CPA:     ${CYAN}http://${server_ip}:${cpa_port}${NC}"
    echo -e "  New API: ${CYAN}http://${server_ip}:${newapi_port}${NC}"
    echo -e "  版本:    ${CYAN}$(git log --oneline -1)${NC}"
}

# ============================================================
# 卸载
# ============================================================
do_uninstall() {
    info "开始卸载 Infra 基础设施..."

    if [ ! -d "$INSTALL_DIR" ]; then
        warn "安装目录不存在 ($INSTALL_DIR)，无需卸载"
        exit 0
    fi

    cd "$INSTALL_DIR"

    # 停止并删除容器
    if [ -f "docker-compose.yml" ]; then
        info "停止并删除容器..."
        $COMPOSE_CMD down -v 2>/dev/null || true
    fi

    # 询问是否删除数据
    local has_data=false
    for dir in pgdata cpa-data newapi-data newapi-logs; do
        [ -d "$INSTALL_DIR/$dir" ] && has_data=true && break
    done

    if [ "$has_data" = true ]; then
        echo ""
        echo -e "  ${YELLOW}数据目录包含:${NC}"
        echo -e "    pgdata/      — PostgreSQL 数据库（CPA + New API）"
        echo -e "    cpa-data/    — CPA 运行数据"
        echo -e "    newapi-data/ — New API 数据"
        echo -e "    newapi-logs/ — New API 日志"
        echo ""
        read -rp "是否删除所有数据？(y/N): " del_data
        case "$del_data" in
            [yY]|[yY][eE][sS])
                ok "数据将随安装目录一并删除"
                ;;
            *)
                local backup_dir="/tmp/infra_data_backup_$(date +%Y%m%d%H%M%S)"
                mkdir -p "$backup_dir"
                for dir in pgdata cpa-data newapi-data newapi-logs; do
                    [ -d "$INSTALL_DIR/$dir" ] && mv "$INSTALL_DIR/$dir" "$backup_dir/"
                done
                # 同时备份 .env
                [ -f "$INSTALL_DIR/.env" ] && cp "$INSTALL_DIR/.env" "$backup_dir/"
                ok "数据已备份到: $backup_dir"
                ;;
        esac
    fi

    # 删除安装目录
    cd /
    rm -rf "$INSTALL_DIR"

    echo ""
    ok "卸载完成"
}

# ============================================================
# 主入口
# ============================================================
main() {
    echo ""
    echo -e "${BOLD}  Infra 基础设施部署工具${NC}"
    echo -e "  CPA + New API + PostgreSQL + Redis"
    echo ""

    check_root
    check_docker

    case "$ACTION" in
        install)    do_install ;;
        update)     do_update ;;
        uninstall)  do_uninstall ;;
        *)          fatal "未知操作: $ACTION" ;;
    esac
}

main
