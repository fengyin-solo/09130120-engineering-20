#!/usr/bin/env python3
"""等待本地基础设施（PostgreSQL / Redis / MinIO）就绪。

由 scripts/dev-up.sh 调用，仅使用 Python 标准库，不依赖虚拟环境中的第三方包。
检测项：
  - PostgreSQL：TCP 可连通（容器 healthcheck 已保证完成初始化）
  - Redis：TCP 连通并能收到 PING -> PONG
  - MinIO：http://localhost:9000/minio/health/live 返回 200

退出码：0 全部就绪；1 超时仍有服务未就绪。
"""
from __future__ import annotations

import argparse
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def parse_simple_env(env_path: str) -> dict[str, str]:
    """解析 backend/.env 中的 KEY=VALUE，不展开变量引用（本项目不需要）。"""
    env: dict[str, str] = {}
    path = Path(env_path)
    if not path.exists():
        return env
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip()
    return env


def tcp_ready(host: str, port: int, timeout: float = 2.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def redis_ready(host: str, port: int) -> bool:
    """通过原生 RESP 协议发送 PING。"""
    try:
        with socket.create_connection((host, port), timeout=2.0) as sock:
            sock.sendall(b"*1\r\n$4\r\nPING\r\n")
            data = sock.recv(64)
            return b"PONG" in data
    except OSError:
        return False


def minio_ready(host: str, port: int) -> bool:
    url = f"http://{host}:{port}/minio/health/live"
    try:
        with urllib.request.urlopen(url, timeout=2.0) as resp:
            return resp.status == 200
    except urllib.error.HTTPError:
        # 服务在响应但还未就绪（503），继续等待
        return False
    except urllib.error.URLError:
        return False
    except OSError:
        return False


def db_target(database_url: str) -> tuple[str, int]:
    parsed = urllib.parse.urlparse(database_url)
    return (parsed.hostname or "localhost", parsed.port or 5432)


def redis_target(redis_url: str) -> tuple[str, int]:
    parsed = urllib.parse.urlparse(redis_url)
    return (parsed.hostname or "localhost", parsed.port or 6379)


def minio_target(endpoint: str) -> tuple[str, int]:
    if ":" in endpoint:
        host, port_s = endpoint.rsplit(":", 1)
        return host, int(port_s)
    return endpoint, 9000


def main() -> int:
    parser = argparse.ArgumentParser(description="等待本地基础设施就绪")
    parser.add_argument("--env", required=True, help="backend/.env 路径")
    parser.add_argument("--timeout", type=int, default=120, help="总超时秒数")
    args = parser.parse_args()

    env = parse_simple_env(args.env)
    db_host, db_port = db_target(
        env.get("DATABASE_URL", "postgresql://seismic:seismic123@localhost:5432/seismic_db")
    )
    redis_host, redis_port = redis_target(env.get("REDIS_URL", "redis://localhost:6379/0"))
    minio_host, minio_port = minio_target(env.get("MINIO_ENDPOINT", "localhost:9000"))

    checks = [
        ("PostgreSQL", db_host, db_port, tcp_ready),
        ("Redis", redis_host, redis_port, redis_ready),
        ("MinIO", minio_host, minio_port, minio_ready),
    ]

    deadline = time.monotonic() + args.timeout
    pending: list[str] = []
    print(f"等待基础设施就绪（超时 {args.timeout}s）……")

    for name, host, port, check in checks:
        sys.stdout.write(f"  {name} ({host}:{port}) ")
        sys.stdout.flush()
        while True:
            try:
                ready = check(host, port)
            except Exception:  # 任何探测异常都视为未就绪，继续重试
                ready = False
            if ready:
                print("就绪")
                break
            if time.monotonic() >= deadline:
                print("超时")
                pending.append(f"{name} ({host}:{port})")
                break
            sys.stdout.write(".")
            sys.stdout.flush()
            time.sleep(1.0)

    if pending:
        print("\n以下服务在超时时间内未就绪：", file=sys.stderr)
        for item in pending:
            print(f"  - {item}", file=sys.stderr)
        print("可使用 docker logs <seismic-postgres|seismic-redis|seismic-minio> 查看原因。",
              file=sys.stderr)
        return 1

    print("全部基础设施就绪")
    return 0


if __name__ == "__main__":
    sys.exit(main())
