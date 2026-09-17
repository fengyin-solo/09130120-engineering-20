#!/usr/bin/env bash
#
# dev-setup.sh — 本地开发环境一键初始化
#
# 按顺序完成：环境预检 → 配置文件 → 基础服务(PostgreSQL/Redis/MinIO)
#             → 后端依赖 → 前端依赖 → 数据初始化 → 环境校验
#
# 特性：
#   - 任何一步失败都会显示步骤名、退出码与日志末尾，便于定位原因
#   - 所有步骤幂等，修复问题后可直接重新执行
#   - 失败步骤的中间产物（半成品虚拟环境、临时配置文件等）会自动清理
#   - 每次运行前清空 .dev-setup/ 下上一次运行的日志
#
# 用法： ./scripts/dev-setup.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RUN_DIR="$ROOT_DIR/.dev-setup"
LOG_DIR="$RUN_DIR/logs"

# 不保留上一次运行的中间产物
rm -rf "$RUN_DIR"
mkdir -p "$LOG_DIR"

# ---------- 输出 ----------
if [ -t 1 ]; then
  C_STEP=$'\033[1;34m'; C_OK=$'\033[1;32m'; C_ERR=$'\033[1;31m'; C_RESET=$'\033[0m'
else
  C_STEP=""; C_OK=""; C_ERR=""; C_RESET=""
fi

STEP_SLUGS=()
STEP_NAMES=()
STEP_FUNCS=()
STEP_INDEX=0
STEP_CLEANUP=()
COMPOSE=()

register_step() {
  STEP_SLUGS+=("$1")
  STEP_NAMES+=("$2")
  STEP_FUNCS+=("$3")
}

cleanup_step_artifacts() {
  local p
  for p in ${STEP_CLEANUP[@]+"${STEP_CLEANUP[@]}"}; do
    [ -n "$p" ] && rm -rf "$p"
  done
  STEP_CLEANUP=()
}

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    cleanup_step_artifacts
  fi
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------- 通用工具 ----------

port_busy() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

wait_for() {
  # wait_for <描述> <compose服务名> <超时秒> <就绪探测命令...>
  local desc="$1" service="$2" timeout="$3"
  shift 3
  local elapsed=0
  until "$@" >/dev/null 2>&1; do
    sleep 2
    elapsed=$((elapsed + 2))
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "[超时] 等待 $desc 就绪（${timeout}s），排查: ${COMPOSE[*]} logs $service"
      return 1
    fi
  done
  echo "[OK] $desc 就绪"
}

# ---------- 步骤 1: 环境预检 ----------

step_preflight() {
  local failed=0 cmd spec port container

  for cmd in docker python3 node npm; do
    if command -v "$cmd" >/dev/null 2>&1; then
      echo "[OK] $cmd: $(command -v "$cmd")"
    else
      echo "[缺失] 命令未安装: $cmd"
      failed=1
    fi
  done

  if command -v docker >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1; then
      COMPOSE=(docker compose)
      echo "[OK] docker compose (v2)"
    elif command -v docker-compose >/dev/null 2>&1; then
      COMPOSE=(docker-compose)
      echo "[OK] docker-compose (v1)"
    else
      echo "[缺失] docker compose（v2 插件或 docker-compose）"
      failed=1
    fi

    if [ "$failed" -eq 0 ] && ! docker info >/dev/null 2>&1; then
      echo "[错误] Docker 守护进程未运行或当前用户无权限访问（启动 Docker，或将用户加入 docker 组）"
      failed=1
    fi
  fi

  if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'; then
      echo "[OK] $(python3 --version 2>&1)"
    else
      echo "[错误] python3 版本需 >= 3.9，当前: $(python3 --version 2>&1)"
      failed=1
    fi
    if python3 -c 'import ensurepip' >/dev/null 2>&1; then
      echo "[OK] python3 venv/ensurepip 可用"
    else
      echo "[错误] python3 缺少 venv/ensurepip 支持（Debian/Ubuntu: sudo apt install python3-venv）"
      failed=1
    fi
  fi

  # 端口检查：已被本项目容器占用的端口视为正常（重复执行场景）
  if [ "$failed" -eq 0 ]; then
    for spec in "5432 seismic-postgres" "6379 seismic-redis" "9000 seismic-minio" "9001 seismic-minio"; do
      port="${spec%% *}"
      container="${spec##* }"
      if docker ps --format '{{.Names}}' | grep -qx "$container"; then
        echo "[OK] 端口 $port: 容器 $container 已在运行"
      elif port_busy "$port"; then
        echo "[错误] 端口 $port 已被其他进程占用（$container 未运行），请释放端口或调整 docker-compose.yml 端口映射"
        failed=1
      else
        echo "[OK] 端口 $port 可用"
      fi
    done
  fi

  [ "$failed" -eq 0 ]
}

# ---------- 步骤 2: 配置文件 ----------

step_env_files() {
  local data_dir="$ROOT_DIR/backend/data/seismic"
  mkdir -p "$data_dir" || return 1
  echo "数据目录: $data_dir"

  if [ -f "$ROOT_DIR/backend/.env" ]; then
    echo "已存在，保留不变: backend/.env"
  else
    local tmp="$ROOT_DIR/backend/.env.dev-setup-tmp"
    STEP_CLEANUP+=("$tmp")
    {
      echo "# 由 scripts/dev-setup.sh 生成（本地开发用，已加入 .gitignore）"
      # 本地开发时数据目录指到仓库内，避免使用需要 root 的 /data/seismic
      sed "s|^SEISMIC_DATA_DIR=.*|SEISMIC_DATA_DIR=$data_dir|" "$ROOT_DIR/backend/.env.example"
    } > "$tmp" || return 1
    mv "$tmp" "$ROOT_DIR/backend/.env" || return 1
    echo "已生成: backend/.env"
  fi

  if [ -f "$ROOT_DIR/frontend/.env" ]; then
    echo "已存在，保留不变: frontend/.env"
  else
    cp "$ROOT_DIR/frontend/.env.example" "$ROOT_DIR/frontend/.env" || return 1
    echo "已生成: frontend/.env"
  fi
}

# ---------- 步骤 3: 基础服务 ----------

step_infra() {
  "${COMPOSE[@]}" up -d postgres || return 1
  wait_for "PostgreSQL" postgres 90 docker exec seismic-postgres pg_isready -U seismic -q || return 1

  "${COMPOSE[@]}" up -d redis || return 1
  wait_for "Redis" redis 60 docker exec seismic-redis redis-cli ping || return 1

  "${COMPOSE[@]}" up -d minio || return 1
  wait_for "MinIO" minio 90 python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:9000/minio/health/live', timeout=2)" || return 1
}

# ---------- 步骤 4: 后端依赖 ----------

step_backend_deps() {
  local venv="$ROOT_DIR/backend/.venv"
  if [ ! -x "$venv/bin/python" ]; then
    rm -rf "$venv"
    STEP_CLEANUP+=("$venv")
    echo "创建虚拟环境: $venv"
    python3 -m venv "$venv" || return 1
  else
    echo "复用已有虚拟环境: $venv"
  fi
  "$venv/bin/python" -m pip install --upgrade pip || return 1
  "$venv/bin/python" -m pip install -r "$ROOT_DIR/backend/requirements.txt" || return 1
  echo "后端依赖安装完成"
}

# ---------- 步骤 5: 前端依赖 ----------

step_frontend_deps() {
  cd "$ROOT_DIR/frontend" || return 1
  if [ -f package-lock.json ]; then
    # npm ci 依据 lock 文件安装，保证不同机器结果一致；每次先清空 node_modules，重跑无残留
    npm ci --include=dev || return 1
  else
    npm install || return 1
  fi
  echo "前端依赖安装完成"
}

# ---------- 步骤 6: 数据初始化 ----------

step_init_data() {
  cd "$ROOT_DIR/backend" || return 1
  "$ROOT_DIR/backend/.venv/bin/python" -m app.init_data || return 1
  "$ROOT_DIR/backend/.venv/bin/python" -m app.seed_data || return 1
}

# ---------- 步骤 7: 环境校验 ----------

step_verify() {
  cd "$ROOT_DIR/backend" || return 1
  "$ROOT_DIR/backend/.venv/bin/python" - <<'PYEOF'
from app.config import get_settings

settings = get_settings()

from sqlalchemy import create_engine, text
engine = create_engine(settings.DATABASE_URL)
with engine.connect() as conn:
    conn.execute(text("SELECT 1"))
print("[OK] 数据库连接正常")

import redis
client = redis.from_url(settings.REDIS_URL, socket_connect_timeout=5)
client.ping()
print("[OK] Redis 连接正常")

from minio import Minio
minio_client = Minio(
    settings.MINIO_ENDPOINT,
    access_key=settings.MINIO_ACCESS_KEY,
    secret_key=settings.MINIO_SECRET_KEY,
    secure=settings.MINIO_SECURE,
)
if minio_client.bucket_exists(settings.MINIO_BUCKET):
    print(f"[OK] MinIO 连接正常，bucket 已存在: {settings.MINIO_BUCKET}")
else:
    minio_client.make_bucket(settings.MINIO_BUCKET)
    print(f"[OK] MinIO 连接正常，已创建 bucket: {settings.MINIO_BUCKET}")
PYEOF
}

# ---------- 主流程 ----------

print_summary() {
  cat <<EOF

${C_OK}本地开发环境初始化完成 ✔${C_RESET}

启动服务（与之前一致）:
  后端:  cd backend && source .venv/bin/activate
         python -m uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
  前端:  cd frontend && npm start

访问入口:
  前端应用      http://localhost:3000
  API 文档      http://localhost:8000/docs
  MinIO 控制台  http://localhost:9001  (minioadmin / minioadmin123)

默认账号: admin / admin123    demo / demo123
EOF
}

usage() {
  cat <<EOF
用法: ./scripts/dev-setup.sh

一键完成本地开发环境准备：环境预检、配置文件生成、
PostgreSQL/Redis/MinIO 启动、后端与前端依赖安装、
数据库建表与示例数据初始化、环境连通性校验。

所有步骤幂等，可重复执行；失败时会显示具体步骤与原因。
EOF
}

main() {
  register_step "preflight"     "环境预检（docker / python3 / node / 端口）"  step_preflight
  register_step "env-files"     "生成配置文件（backend/.env、frontend/.env）" step_env_files
  register_step "infra"         "启动基础服务（PostgreSQL → Redis → MinIO）"  step_infra
  register_step "backend-deps"  "安装后端依赖（backend/.venv）"               step_backend_deps
  register_step "frontend-deps" "安装前端依赖（npm ci）"                      step_frontend_deps
  register_step "init-data"     "初始化数据（建表 / 默认用户 / 示例数据）"    step_init_data
  register_step "verify"        "环境校验（数据库 / 缓存 / 对象存储）"        step_verify

  local total=${#STEP_NAMES[@]} i slug name func log_file rc
  echo "本地开发环境初始化开始（日志目录: $LOG_DIR）"

  for ((i=0; i<total; i++)); do
    STEP_INDEX=$i
    STEP_CLEANUP=()
    slug="${STEP_SLUGS[$i]}"
    name="${STEP_NAMES[$i]}"
    func="${STEP_FUNCS[$i]}"
    log_file="$LOG_DIR/$(printf '%02d' $((i+1)))-$slug.log"

    printf '\n%s[%d/%d]%s %s\n' "$C_STEP" $((i+1)) "$total" "$C_RESET" "$name"
    if "$func" >"$log_file" 2>&1; then
      printf '%s✔ 完成:%s %s\n' "$C_OK" "$C_RESET" "$name"
    else
      rc=$?
      cleanup_step_artifacts
      printf '%s✘ 失败 [%d/%d]: %s (退出码 %d)%s\n' "$C_ERR" $((i+1)) "$total" "$name" "$rc" "$C_RESET" >&2
      echo "  完整日志: $log_file" >&2
      echo "  ---- 日志末尾 30 行 ----" >&2
      tail -n 30 "$log_file" >&2 || true
      echo "  ------------------------" >&2
      echo "  修复上述问题后重新执行 ./scripts/dev-setup.sh 即可，已完成的步骤会自动跳过或复用。" >&2
      exit "$rc"
    fi
  done

  print_summary
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi
if [ $# -gt 0 ]; then
  echo "未知参数: $1" >&2
  usage >&2
  exit 2
fi

main
