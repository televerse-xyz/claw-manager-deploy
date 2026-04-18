#!/bin/bash

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 默认镜像
BACKEND_IMAGE_DEFAULT="crpi-pbzlbo78mwdo9lmb.cn-shenzhen.personal.cr.aliyuncs.com/televerse/claw-manager-backend:latest"
FRONTEND_IMAGE_DEFAULT="crpi-pbzlbo78mwdo9lmb.cn-shenzhen.personal.cr.aliyuncs.com/televerse/claw-manager-frontend:latest"

echo -e "${GREEN}========== Claw Manager 部署脚本 ==========${NC}"

# 0. 判断是否为 Ubuntu
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" != "ubuntu" ] && [[ "$ID_LIKE" != *"ubuntu"* ]] && [[ "$ID_LIKE" != *"debian"* ]]; then
        echo -e "${RED}错误：当前系统不是 Ubuntu/Debian，本脚本仅支持 Ubuntu 环境。${NC}"
        exit 1
    fi
else
    echo -e "${RED}错误：无法识别操作系统。${NC}"
    exit 1
fi

# 1. 检查 Docker 是否安装
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}Docker 未安装。${NC}"
    read -rp "是否安装 Docker？ [ok/N]: " install_docker
    if [[ "$install_docker" =~ ^[Oo][Kk]$ ]] || [[ "$install_docker" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        echo -e "${YELLOW}正在安装 Docker...${NC}"

        # Set up Docker's apt repository
        sudo apt-get update
        sudo apt-get install -y ca-certificates curl
        sudo install -m 0755 -d /etc/apt/keyrings
        sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc

        # Add the repository to Apt sources (deb822 format)
        sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

        sudo apt-get update

        # Install Docker packages
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        # Start Docker service
        sudo systemctl start docker
        sudo systemctl enable docker

        echo -e "${GREEN}Docker 安装完成。${NC}"
    else
        echo -e "${RED}取消安装，退出。${NC}"
        exit 1
    fi
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

# 2. 要求用户输入 Docker 账号密码并登录
echo ""
echo -e "${YELLOW}请输入 Docker Hub 账号信息进行登录（输入内容不会显示在屏幕上）：${NC}"
read -rp "Docker Username: " docker_username
read -srp "Docker Password: " docker_password
 echo ""

if [ -z "$docker_username" ] || [ -z "$docker_password" ]; then
    echo -e "${RED}错误: Username 和 Password 不能为空。${NC}"
    exit 1
fi

echo -e "${YELLOW}正在登录 Docker Hub...${NC}"
if echo "$docker_password" | docker login -u "$docker_username" --password-stdin > /dev/null 2>&1; then
    echo -e "${GREEN}Docker 登录成功。${NC}"
else
    echo -e "${RED}Docker 登录失败，请检查账号密码是否正确。${NC}"
    exit 1
fi

# 3. 输入后端和前端镜像
echo ""
echo -e "${YELLOW}请输入后端镜像名称（直接回车使用默认值）：${NC}"
echo -e "${YELLOW}默认: ${BACKEND_IMAGE_DEFAULT}${NC}"
read -rp "Backend Image: " backend_image
BACKEND_IMAGE="${backend_image:-$BACKEND_IMAGE_DEFAULT}"

echo ""
echo -e "${YELLOW}请输入前端镜像名称（直接回车使用默认值）：${NC}"
echo -e "${YELLOW}默认: ${FRONTEND_IMAGE_DEFAULT}${NC}"
read -rp "Frontend Image: " frontend_image
FRONTEND_IMAGE="${frontend_image:-$FRONTEND_IMAGE_DEFAULT}"

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
    group_add:
      - "${DOCKER_GID:-998}"
    depends_on:
      config-init:
        condition: service_completed_successfully
      postgres:
        condition: service_healthy

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
    entrypoint:
      - /bin/sh
      - -ec
      - |
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
