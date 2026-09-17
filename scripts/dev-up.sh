#!/usr/bin/env bash
#
# 一键准备本地开发环境
#
# 依次完成：
#   1. 前置检查（docker / python3 / venv）
#   2. 生成本地配置 backend/.env（已存在则保留）
#   3. 启动基础设施：PostgreSQL、Redis、MinIO
#   4. 等待三个服务就绪
#   5. 创建后端虚拟环境并安装锁定版本依赖
#   6. 建表、初始化示例数据、校验缓存与对象存储（含自动建桶）
#
# 任何一步失败都会立即停止，标明失败步骤、退出码与日志位置；
# 修复后重新执行本脚本即可，各步骤均幂等。
#
# 用法：
#   scripts/dev-up.sh            # 准备/修复本地环境
#   scripts/dev-up.sh --clean    # 清空上次的容器、数据卷、虚拟环境、配置后重新准备
#   scripts/dev-up.sh --help
#
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$ROOT_DIR/backend"
FRONTEND_DIR="$ROOT_DIR/frontend"
LOG_DIR="$ROOT_DIR/.dev-logs"
ENV_FILE="$BACKEND_DIR/.env"
VENV_DIR="$BACKEND_DIR/.venv"
DATA_DIR="$BACKEND_DIR/data"
STAMP_FILE="$VENV_DIR/.requirements.sha256"
INFRA_SERVICES=(postgres redis minio)

mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------- 输出与错误处理

if [[ -t 1 ]]; then
  C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'; C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_BLUE=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_DIM=""; C_RESET=""
fi

STEP=0
TOTAL_STEPS=6
CURRENT_STEP=""
LOG_FILE=""
ENV_TMP=""
DC=()

say()  { printf '%s\n' "$*"; }
info() { printf '%s%s%s\n' "$C_BLUE" "$*" "$C_RESET"; }
pass() { printf '%s✓ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%s! %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
die()  { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

cleanup() {
  if [[ -n "$ENV_TMP" && -f "$ENV_TMP" ]]; then
    rm -f "$ENV_TMP"
  fi
  return 0
}
trap cleanup EXIT

on_error() {
  local rc=$?
  printf '\n%s✗ 步骤 %d「%s」失败（退出码 %d）%s\n' "$C_RED" "$STEP" "$CURRENT_STEP" "$rc" "$C_RESET" >&2
  if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
    printf '%s完整日志：%s%s\n' "$C_DIM" "$LOG_FILE" "$C_RESET" >&2
    printf '%s──────── 日志末尾 ────────%s\n' "$C_DIM" "$C_RESET" >&2
    tail -n 20 "$LOG_FILE" >&2 || true
    printf '%s──────────────────────────%s\n' "$C_DIM" "$C_RESET" >&2
  fi
  say ""
  warn "请根据上面的报错修复后，重新执行：scripts/dev-up.sh"
  warn "如需从零开始（删除容器/数据卷/虚拟环境），执行：scripts/dev-up.sh --clean"
  exit "$rc"
}
trap on_error ERR

begin_step() {
  local title="$1" log_name="$2"
  STEP=$((STEP + 1))
  CURRENT_STEP="$title"
  LOG_FILE="$LOG_DIR/$(printf '%02d-%s.log' "$STEP" "$log_name")"
  : > "$LOG_FILE"
  printf '\n%s▶ 步骤 %d/%d：%s%s\n' "$C_BLUE" "$STEP" "$TOTAL_STEPS" "$title" "$C_RESET"
}

# 执行命令：输出实时显示并同时写入当前步骤日志，保留原始退出码
run_logged() {
  "$@" 2>&1 | tee -a "$LOG_FILE"
  return "${PIPESTATUS[0]}"
}

# ---------------------------------------------------------------- 步骤实现

detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    DC=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    DC=(docker-compose)
  else
    die "未找到 Docker Compose，请安装 Docker Desktop（含 compose 插件）或 docker-compose。"
  fi
}

step_preflight() {
  command -v docker >/dev/null 2>&1 || die "未找到 docker，请先安装并启动 Docker Desktop。"
  docker info >/dev/null 2>&1 || die "docker 守护进程未运行，请先启动 Docker 后重试。"
  detect_compose
  command -v python3 >/dev/null 2>&1 || die "未找到 python3（需要 Python 3.10+）。"
  python3 -c 'import venv, ensurepip' >/dev/null 2>&1 \
    || die "python3 缺少 venv 模块。Debian/Ubuntu 请执行：sudo apt install python3-venv"

  say "  docker：$(docker --version 2>/dev/null)"
  say "  compose：$("${DC[@]}" version 2>/dev/null | head -n1)"
  say "  python：$(python3 --version 2>&1)"
  pass "前置检查通过"
}

step_env() {
  if [[ -f "$ENV_FILE" ]]; then
    say "  已存在 $ENV_FILE，保留现有配置（如需重置请使用 --clean）"
    pass "本地配置就绪"
    return
  fi

  ENV_TMP="$(mktemp "$BACKEND_DIR/.env.XXXXXX")"
  cat > "$ENV_TMP" <<EOF
# 由 scripts/dev-up.sh 自动生成，本地开发使用
DATABASE_URL=postgresql://seismic:seismic123@localhost:5432/seismic_db
REDIS_URL=redis://localhost:6379/0
MINIO_ENDPOINT=localhost:9000
MINIO_ACCESS_KEY=minioadmin
MINIO_SECRET_KEY=minioadmin123
MINIO_SECURE=false
MINIO_BUCKET=seismic-data

SECRET_KEY=dev-only-secret-key-do-not-use-in-production
ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=10080

SEISMIC_DATA_DIR=$DATA_DIR
MAX_UPLOAD_SIZE=10737418240
CHUNK_SIZE=8388608
EOF
  mv -f "$ENV_TMP" "$ENV_FILE"
  ENV_TMP=""
  say "  已生成 $ENV_FILE"
  pass "本地配置就绪"
}

step_infra_up() {
  run_logged "${DC[@]}" -f "$ROOT_DIR/docker-compose.yml" up -d "${INFRA_SERVICES[@]}"
  pass "基础设施容器已启动（PostgreSQL / Redis / MinIO）"
}

step_wait() {
  run_logged python3 "$ROOT_DIR/scripts/dev-wait.py" --env "$ENV_FILE" --timeout 120
  pass "数据库、缓存、对象存储均已就绪"
}

hash_requirements() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$BACKEND_DIR/requirements.txt" | awk '{print $1}'
  else
    shasum -a 256 "$BACKEND_DIR/requirements.txt" | awk '{print $1}'
  fi
}

step_deps() {
  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    say "  创建虚拟环境 $VENV_DIR"
    run_logged python3 -m venv "$VENV_DIR"
  else
    say "  虚拟环境已存在，跳过创建"
  fi

  local want have
  want="$(hash_requirements)"
  have="$(cat "$STAMP_FILE" 2>/dev/null || true)"
  if [[ "$want" == "$have" ]]; then
    say "  依赖与 requirements.txt 一致，跳过安装"
  else
    say "  安装锁定版本依赖（requirements.txt），首次执行需要几分钟……"
    run_logged "$VENV_DIR/bin/python" -m pip install --upgrade pip
    run_logged "$VENV_DIR/bin/python" -m pip install -r "$BACKEND_DIR/requirements.txt"
    printf '%s\n' "$want" > "$STAMP_FILE"
  fi
  pass "后端依赖就绪"
}

step_init() {
  # pydantic-settings 从当前工作目录读取 .env，因此必须在 backend/ 下执行
  (
    cd "$BACKEND_DIR"
    "$VENV_DIR/bin/python" -m app.init_data
  ) 2>&1 | tee -a "$LOG_FILE"
  return "${PIPESTATUS[0]}"
}

# ---------------------------------------------------------------- 清理模式

do_clean() {
  warn "即将删除：三个基础设施容器及其数据卷、backend/.venv、backend/.env、backend/data、.dev-logs"
  if command -v docker >/dev/null 2>&1; then
    detect_compose
    say "停止并删除容器与数据卷……"
    "${DC[@]}" -f "$ROOT_DIR/docker-compose.yml" down -v --remove-orphans || true
  fi
  rm -rf "$VENV_DIR" "$ENV_FILE" "$DATA_DIR" "$LOG_DIR"
  mkdir -p "$LOG_DIR"
  pass "清理完成，开始全新准备"
}

usage() {
  cat <<'EOF'
一键准备本地开发环境

依次完成：
  1. 前置检查（docker / python3 / venv）
  2. 生成本地配置 backend/.env（已存在则保留）
  3. 启动基础设施：PostgreSQL、Redis、MinIO
  4. 等待三个服务就绪
  5. 创建后端虚拟环境并安装锁定版本依赖
  6. 建表、初始化示例数据、校验缓存与对象存储（含自动建桶）

任何一步失败都会立即停止，标明失败步骤、退出码与日志位置；
修复后重新执行本脚本即可，各步骤均幂等。

用法：
  scripts/dev-up.sh            准备/修复本地环境
  scripts/dev-up.sh --clean    清空上次的容器、数据卷、虚拟环境、配置后重新准备
  scripts/dev-up.sh --help     显示本帮助
EOF
}

# ---------------------------------------------------------------- 主流程

main() {
  local clean=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --clean) clean=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数：$1（支持 --clean / --help）" ;;
    esac
    shift
  done

  info "本地开发环境一键准备（仓库：$ROOT_DIR）"
  [[ "$clean" == "1" ]] && do_clean

  begin_step "前置检查" "preflight";        step_preflight
  begin_step "生成本地配置" "env";           step_env
  begin_step "启动基础设施" "infra-up";      step_infra_up
  begin_step "等待服务就绪" "wait";          step_wait
  begin_step "安装后端依赖" "deps";          step_deps
  begin_step "初始化数据库与示例数据" "init"; step_init

  printf '\n%s══════════════════════════════════════════════%s\n' "$C_GREEN" "$C_RESET"
  pass "环境准备完成"
  say ""
  say "启动后端（终端 1）："
  say "  cd backend && .venv/bin/python -m uvicorn app.main:app --reload --host 0.0.0.0 --port 8000"
  say "启动前端（方式照旧，终端 2）："
  say "  cd frontend && npm install && npm start"
  say ""
  say "访问地址：前端 http://localhost:3000  后端文档 http://localhost:8000/docs"
  say "默认账号：admin / admin123    demo / demo123"
  say "MinIO 控制台：http://localhost:9001（minioadmin / minioadmin123）"
  say ""
  say "本次各步骤日志见：$LOG_DIR"
}

main "$@"
