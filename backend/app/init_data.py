"""本地环境初始化：建表、写入示例用户、校验缓存与对象存储。

由 scripts/dev-up.sh 调用，可安全重复执行：
  - 表通过 Base.metadata.create_all 幂等创建（不存在才建）；
  - 默认用户按用户名判重，已存在则跳过，不改动已有数据；
  - MinIO 桶不存在时自动创建。

任何一步失败都会抛出异常并以非零退出码结束，便于编排脚本定位卡点。
"""
import sys
import time

from sqlalchemy import text

from .auth import get_password_hash
from .config import get_settings
from .database import Base, SessionLocal, engine
from . import models  # noqa: F401  导入即注册全部表模型

settings = get_settings()

MAX_ATTEMPTS = 30
RETRY_INTERVAL = 1.0


def _retry(description, check):
    last_error = None
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            check()
            return
        except Exception as e:
            last_error = e
            if attempt == 1:
                print(f"  等待 {description} ...")
            time.sleep(RETRY_INTERVAL)
    raise RuntimeError(f"{description} 在 {MAX_ATTEMPTS} 次尝试后仍不可用：{last_error}")


def check_database():
    with engine.connect() as conn:
        conn.execute(text("SELECT 1"))


def check_redis():
    import redis
    client = redis.from_url(settings.REDIS_URL)
    if not client.ping():
        raise RuntimeError("Redis PING 返回非预期结果")


def ensure_bucket():
    from minio import Minio

    client = Minio(
        settings.MINIO_ENDPOINT,
        access_key=settings.MINIO_ACCESS_KEY,
        secret_key=settings.MINIO_SECRET_KEY,
        secure=settings.MINIO_SECURE,
    )
    if not client.bucket_exists(settings.MINIO_BUCKET):
        client.make_bucket(settings.MINIO_BUCKET)
        print(f"  已创建对象存储桶：{settings.MINIO_BUCKET}")


def seed_users():
    defaults = [
        {
            "username": "admin",
            "email": "admin@seismic.local",
            "full_name": "System Administrator",
            "password": "admin123",
            "is_admin": True,
        },
        {
            "username": "demo",
            "email": "demo@seismic.local",
            "full_name": "Demo User",
            "password": "demo123",
            "is_admin": False,
        },
    ]

    db = SessionLocal()
    created = 0
    try:
        for spec in defaults:
            exists = (
                db.query(models.User)
                .filter(models.User.username == spec["username"])
                .first()
            )
            if exists:
                continue
            db.add(models.User(
                username=spec["username"],
                email=spec["email"],
                full_name=spec["full_name"],
                hashed_password=get_password_hash(spec["password"]),
                is_active=True,
                is_admin=spec["is_admin"],
            ))
            created += 1
        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()

    if created:
        print(f"  已写入 {created} 个默认用户（admin / demo）")
    else:
        print("  默认用户已存在，跳过")


def main():
    print("初始化本地环境……")

    print("[1/4] 检查数据库连接")
    _retry("数据库", check_database)

    print("[2/4] 创建数据表（已存在则跳过）")
    Base.metadata.create_all(bind=engine)

    print("[3/4] 检查缓存（Redis）")
    _retry("Redis", check_redis)

    print("[4/4] 检查对象存储（MinIO）并创建存储桶")
    _retry("MinIO", ensure_bucket)

    print("写入示例数据")
    seed_users()

    print("环境初始化完成。")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"环境初始化失败：{e}", file=sys.stderr)
        sys.exit(1)
