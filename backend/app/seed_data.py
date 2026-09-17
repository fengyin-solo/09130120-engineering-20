"""示例数据初始化脚本（本地开发用，幂等，可重复执行）。

在 init_data.py 创建的默认用户基础上，灌入一层示例数据：
演示项目、项目成员与示例井，数据结构与通过 API 创建的一致。
已存在的记录（按自然键匹配）会跳过，不会修改已有数据。
"""
import sys

from .database import SessionLocal, engine, Base
from . import models

DEMO_PROJECT_NAME = "演示项目"
DEMO_PROJECT_DESCRIPTION = "本地开发示例项目，由 dev-setup 自动创建，可安全删除。"

DEMO_WELLS = [
    {
        "name": "示例井-A1",
        "uwi": "DEMO-A1",
        "x": 435000.0,
        "y": 3985000.0,
        "kb_elevation": 152.3,
        "total_depth": 3250.0,
    },
    {
        "name": "示例井-B2",
        "uwi": "DEMO-B2",
        "x": 436200.0,
        "y": 3986200.0,
        "kb_elevation": 148.7,
        "total_depth": 2980.0,
    },
]


def get_or_create_project(db, admin):
    project = db.query(models.Project).filter(
        models.Project.name == DEMO_PROJECT_NAME,
        models.Project.created_by == admin.id,
    ).first()
    if project:
        print(f"  项目已存在，跳过: {DEMO_PROJECT_NAME} (id={project.id})")
        return project
    project = models.Project(
        name=DEMO_PROJECT_NAME,
        description=DEMO_PROJECT_DESCRIPTION,
        created_by=admin.id,
    )
    db.add(project)
    db.flush()
    print(f"  创建项目: {DEMO_PROJECT_NAME} (id={project.id})")
    return project


def ensure_member(db, project_id, user_id, role, username):
    member = db.query(models.ProjectMember).filter(
        models.ProjectMember.project_id == project_id,
        models.ProjectMember.user_id == user_id,
    ).first()
    if member:
        print(f"  成员已存在，跳过: {username} (role={member.role})")
        return
    db.add(models.ProjectMember(project_id=project_id, user_id=user_id, role=role))
    print(f"  添加成员: {username} (role={role})")


def ensure_well(db, project_id, spec):
    well = db.query(models.Well).filter(
        models.Well.project_id == project_id,
        models.Well.name == spec["name"],
    ).first()
    if well:
        print(f"  井已存在，跳过: {spec['name']}")
        return
    db.add(models.Well(project_id=project_id, **spec))
    print(f"  创建井: {spec['name']}")


def seed():
    Base.metadata.create_all(bind=engine)
    db = SessionLocal()
    try:
        admin = db.query(models.User).filter(models.User.username == "admin").first()
        demo = db.query(models.User).filter(models.User.username == "demo").first()
        if not admin or not demo:
            print("默认用户不存在，请先运行: python -m app.init_data", file=sys.stderr)
            return 1

        project = get_or_create_project(db, admin)
        ensure_member(db, project.id, admin.id, "owner", admin.username)
        ensure_member(db, project.id, demo.id, "editor", demo.username)
        for spec in DEMO_WELLS:
            ensure_well(db, project.id, spec)

        db.commit()
        print("示例数据初始化完成。")
        return 0
    except Exception as e:
        db.rollback()
        print(f"示例数据初始化失败: {e}", file=sys.stderr)
        return 1
    finally:
        db.close()


if __name__ == "__main__":
    sys.exit(seed())
