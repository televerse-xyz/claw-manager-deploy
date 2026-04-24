#!/bin/bash

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 默认镜像前缀和标签
BACKEND_IMAGE_PREFIX="crpi-pbzlbo78mwdo9lmb.cn-shenzhen.personal.cr.aliyuncs.com/televerse/claw-manager-backend"
FRONTEND_IMAGE_PREFIX="crpi-pbzlbo78mwdo9lmb.cn-shenzhen.personal.cr.aliyuncs.com/televerse/claw-manager-frontend"
DEFAULT_TAG="latest"

echo -e "${GREEN}========== Claw Manager 部署脚本 ==========${NC}"

# 1. 检查 Docker 是否安装
if ! command -v docker &> /dev/null; then
    echo -e "${RED}错误: Docker 未安装，请先安装 Docker。${NC}"
    exit 1
fi

# 检查当前用户是否有 Docker 使用权限
if ! docker ps &> /dev/null; then
    if [ "$EUID" -eq 0 ]; then
        echo -e "${RED}错误: Docker 服务未运行或安装异常。${NC}"
        exit 1
    else
        echo -e "${RED}错误: 当前用户无 Docker 使用权限。${NC}"
        # 如果用户刚安装完，尝试将其加入 docker 组
        if groups "$USER" | grep -qw docker; then
            echo -e "${YELLOW}用户已在 docker 组，请重新登录后再次运行本脚本。${NC}"
        else
            echo -e "${YELLOW}正在将当前用户加入 docker 组...${NC}"
            sudo usermod -aG docker "$USER"
            echo -e "${GREEN}已加入 docker 组，请重新登录后再次运行本脚本。${NC}"
        fi
        exit 1
    fi
fi

# 检查 Docker Compose 是否可用
if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
elif docker-compose version &> /dev/null; then
    COMPOSE_CMD="docker-compose"
else
    echo -e "${RED}错误: Docker Compose 未安装，请先安装 Docker Compose。${NC}"
    exit 1
fi

echo -e "${GREEN}Docker 和 Docker Compose 检查通过。${NC}"

# 2. 输入后端和前端镜像标签
echo ""
echo -e "${YELLOW}请输入后端镜像标签（直接回车使用默认值）：${NC}"
echo -e "${YELLOW}默认: ${DEFAULT_TAG}${NC}"
read -rp "Backend Tag: " backend_tag
backend_tag="${backend_tag:-$DEFAULT_TAG}"
BACKEND_IMAGE="${BACKEND_IMAGE_PREFIX}:${backend_tag}"

echo ""
echo -e "${YELLOW}请输入前端镜像标签（直接回车使用默认值）：${NC}"
echo -e "${YELLOW}默认: ${DEFAULT_TAG}${NC}"
read -rp "Frontend Tag: " frontend_tag
frontend_tag="${frontend_tag:-$DEFAULT_TAG}"
FRONTEND_IMAGE="${FRONTEND_IMAGE_PREFIX}:${frontend_tag}"

# 3. Docker Login（可选）
echo ""
echo -e "${YELLOW}是否需要登录 Docker 镜像仓库？${NC}"
read -rp "登录镜像仓库? [y/N]: " need_login
if [[ "$need_login" =~ ^[Yy]$ ]]; then
    # 从后端镜像地址自动提取 registry 域名
    REGISTRY=$(echo "$BACKEND_IMAGE" | cut -d'/' -f1)
    echo -e "${YELLOW}默认 Registry: ${REGISTRY}${NC}"
    read -rp "Registry (直接回车使用默认值): " input_registry
    REGISTRY="${input_registry:-$REGISTRY}"

    read -rp "用户名: " docker_username
    read -srp "密码: " docker_password
    echo ""  # 换行，因为密码输入没有回显

    echo -e "${YELLOW}正在登录 ${REGISTRY}...${NC}"
    if echo "$docker_password" | docker login "$REGISTRY" --username "$docker_username" --password-stdin; then
        echo -e "${GREEN}Docker 登录成功。${NC}"
    else
        echo -e "${RED}Docker 登录失败。${NC}"
        exit 1
    fi
fi

# 4. 拉取后端和前端镜像
echo ""
echo -e "${YELLOW}正在拉取后端镜像 ${BACKEND_IMAGE}...${NC}"
if docker pull "$BACKEND_IMAGE"; then
    echo -e "${GREEN}后端镜像拉取成功。${NC}"
else
    echo -e "${RED}后端镜像拉取失败。${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}正在拉取前端镜像 ${FRONTEND_IMAGE}...${NC}"
if docker pull "$FRONTEND_IMAGE"; then
    echo -e "${GREEN}前端镜像拉取成功。${NC}"
else
    echo -e "${RED}前端镜像拉取失败。${NC}"
    exit 1
fi

# 5. 切换到脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 6. 生成 docker-compose.yml
echo ""
echo -e "${YELLOW}正在生成 docker-compose.yml...${NC}"

cat <<'EOF' > docker-compose.yml
services:
  postgres:
    image: postgres:18.3-bookworm
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: claw-manager
    logging:
      driver: local
      options:
        max-size: "50m"
        max-file: "20"
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql
    healthcheck:
      test: [ "CMD-SHELL", "pg_isready -U postgres -d claw-manager" ]
      interval: 5s
      timeout: 5s
      retries: 10

  backend:
    image: __BACKEND_IMAGE__
    user: "0:0"
    logging:
      driver: local
      options:
        max-size: "50m"
        max-file: "20"
    ports:
      - "8080:8080"
    environment:
      DOCKER_HOST: unix:///var/run/docker.sock
      CONFIG_FILE_PATH: /config/config.toml
    volumes:
      - backend_config:/config:ro
      - /var/run/docker.sock:/var/run/docker.sock
      - samba_config:/etc/samba
    group_add:
      - "${DOCKER_GID:-998}"
    depends_on:
      config-init:
        condition: service_completed_successfully
      postgres:
        condition: service_healthy

  samba:
    image: dockurr/samba:4.23.5
    container_name: claw-manager-samba
    logging:
      driver: local
      options:
        max-size: "50m"
        max-file: "20"
    ports:
      - "139:139"
      - "445:445"
    volumes:
      - /var/lib/docker/volumes:/docker-volumes:rw
      - samba_config:/etc/samba
    restart: unless-stopped
    environment:
      USER: "sangbo"
      PASS: "sangbo"
      USERID: 0
      GROUPID: 0
    depends_on:
      config-init:
        condition: service_completed_successfully

  config-init:
    image: postgres:18.3-bookworm
    logging:
      driver: local
      options:
        max-size: "50m"
        max-file: "20"
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - backend_config:/config
      - samba_config:/etc/samba
    entrypoint:
      - /bin/sh
      - -ec
      - |
        echo "=== Init config + samba ==="

        db_password="$$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
        admin_password="$$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"

        if [ -f /config/config.toml ]; then
          existing_db_password="$$(sed -n 's/^Password = "\(.*\)"/\1/p' /config/config.toml | head -n 1)"
          existing_admin_password="$$(sed -n 's/^AdminPassword = "\(.*\)"/\1/p' /config/config.toml | head -n 1)"
          if [ -n "$${existing_db_password}" ]; then
            db_password="$${existing_db_password}"
          fi
          if [ -n "$${existing_admin_password}" ]; then
            admin_password="$${existing_admin_password}"
          fi
        fi

        until pg_isready -h postgres -U postgres -d claw-manager >/dev/null 2>&1; do
          sleep 1
        done

        if ! PGPASSWORD="$${db_password}" psql -h postgres -U postgres -d postgres -v ON_ERROR_STOP=1 -c "SELECT 1;" >/dev/null 2>&1; then
          PGPASSWORD="postgres" psql -h postgres -U postgres -d postgres -v ON_ERROR_STOP=1 -c "ALTER USER postgres WITH PASSWORD '$${db_password}';"
        fi

        cat > /config/config.toml <<EOFC
        Profile = "dev"
        ServiceName = "claw-manager"
        AdminPassword = "$${admin_password}"

        [Postgres]
        Host = "postgres"
        Port = 5432
        Username = "postgres"
        Password = "$${db_password}"
        EOFC

        echo "=== Init samba config ==="

        if [ ! -f /etc/samba/smb.conf ]; then
          cat > /etc/samba/smb.conf <<'EOFSMB'
        [global]
           workgroup = WORKGROUP
           security = user
           map to guest = Never
           disable netbios = yes
           browseable = no
           create mask = 0664
           directory mask = 0775
           force user = root
           force group = root
        EOFSMB
        fi

        echo "=== Init done ==="

  frontend:
    image: __FRONTEND_IMAGE__
    logging:
      driver: local
      options:
        max-size: "50m"
        max-file: "20"
    ports:
      - "3000:80"
    depends_on:
      - backend

volumes:
  postgres_data:
  backend_config:
  samba_config:
EOF

# 替换占位符为实际镜像
sed -i "s|__BACKEND_IMAGE__|${BACKEND_IMAGE}|g" docker-compose.yml
sed -i "s|__FRONTEND_IMAGE__|${FRONTEND_IMAGE}|g" docker-compose.yml

echo -e "${GREEN}docker-compose.yml 生成成功。${NC}"

# 7. 执行部署
echo ""
echo -e "${GREEN}开始执行 docker-compose.yml...${NC}"
$COMPOSE_CMD up -d

echo ""
echo -e "${GREEN}部署完成！${NC}"
echo -e "${GREEN}服务状态：${NC}"
$COMPOSE_CMD ps
