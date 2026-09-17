import sys

from sqlalchemy.orm import Session
from .database import SessionLocal, engine, Base
from . import models
from .auth import get_password_hash


def init_db():
    Base.metadata.create_all(bind=engine)
    db = SessionLocal()
    try:
        admin_user = db.query(models.User).filter(models.User.username == "admin").first()
        if not admin_user:
            admin = models.User(
                username="admin",
                email="admin@seismic.local",
                full_name="System Administrator",
                hashed_password=get_password_hash("admin123"),
                is_active=True,
                is_admin=True
            )
            db.add(admin)

        demo_user = db.query(models.User).filter(models.User.username == "demo").first()
        if not demo_user:
            demo = models.User(
                username="demo",
                email="demo@seismic.local",
                full_name="Demo User",
                hashed_password=get_password_hash("demo123"),
                is_active=True,
                is_admin=False
            )
            db.add(demo)

        db.commit()
        print("Database initialized with default users.")
    except Exception as e:
        print(f"Error initializing database: {e}", file=sys.stderr)
        db.rollback()
        raise
    finally:
        db.close()


if __name__ == "__main__":
    init_db()
