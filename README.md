# Seismic Data Visualization - 三维地震数据可视化系统

## 项目概述

Seismic Data Visualization 是一个用于油田地震数据三维可视化的完整系统，包含前端用户界面与后端数据服务。系统支持地震数据体的交互式浏览、切片分析、属性参数调整、三维空间测量及井数据管理功能，能够高效处理大规模地震勘探数据。

## 技术栈

### 后端
- **框架**: FastAPI 0.104.1
- **数据库**: PostgreSQL 15（支持SQLite降级）
- **缓存**: Redis 7（支持内存缓存降级）
- **对象存储**: MinIO
- **地震数据处理**: segyio 1.9.11
- **密码加密**: bcrypt
- **数值计算**: NumPy, SciPy, Pandas

### 前端
- **框架**: React 18 + TypeScript
- **3D渲染**: Three.js + @react-three/fiber
- **UI组件**: Ant Design 5
- **状态管理**: Redux Toolkit
- **路由**: React Router 6

### 部署
- Docker & Docker Compose
- 容器化部署

## 核心功能

### 数据管理
- SEG-Y格式地震数据上传与解析
- 自动提取数据元信息与统计特征
- 项目级数据组织与管理
- 子体积数据提取与导出

### 井数据管理
- 井基础信息管理（坐标、井深、海拔等）
- 测井曲线数据管理
- 项目级井数据组织

### 三维可视化
- 高质量三维地质模型渲染
- 体绘制（Volume Rendering）- 支持模拟数据演示
- 支持多种颜色映射方案（seismic、gray、rainbow）

### 交互分析
- Inline/Crossline/深度切片分析
- 交互式切片浏览与参数调节
- 实时切片图像生成
- 切片数据JSON格式导出

### 空间测量
- 三维距离测量
- 多边形面积计算
- 体积测量

### 标注系统
- 支持多种标注类型
- 用户自定义标注属性
- 几何信息与属性数据存储

### 权限管理
- 基于角色的访问控制（RBAC）
- 项目级成员管理
- 支持查看者/编辑者/所有者角色
- 管理员全局权限

## 快速开始

### 使用 Docker Compose（推荐）

```bash
# 克隆项目
git clone <repository-url>
cd yel3-1

# 启动所有服务
docker-compose up -d

# 初始化数据库（创建默认用户）
docker exec seismic-backend python -m app.init_data

# 访问前端应用
# http://localhost:3000

# 访问API文档
# http://localhost:8000/docs
```

### 本地开发

#### 一键初始化（推荐）

```bash
./scripts/dev-setup.sh
```

一条命令按顺序完成全部准备工作：

| 步骤 | 内容 |
|------|------|
| 1. 环境预检 | 检查 docker / docker compose / python3 / node / npm 及端口占用 |
| 2. 配置文件 | 生成 `backend/.env`、`frontend/.env`（已存在则保留，不会覆盖） |
| 3. 基础服务 | 依次启动 PostgreSQL → Redis → MinIO，逐个等待就绪 |
| 4. 后端依赖 | 创建 `backend/.venv` 虚拟环境并安装 `requirements.txt` |
| 5. 前端依赖 | `npm ci`（依据 package-lock.json，保证不同机器结果一致） |
| 6. 数据初始化 | 建表、创建默认用户、灌入示例项目与井数据（幂等） |
| 7. 环境校验 | 检查数据库 / Redis / MinIO 连通性，确保 MinIO bucket 存在 |

- 任一步骤失败时，会显示失败的步骤名、退出码与日志末尾 30 行；完整日志在 `.dev-setup/logs/`（每次运行前自动清空，不残留上一次的中间产物）。
- 修复问题后直接重新执行 `./scripts/dev-setup.sh` 即可：所有步骤幂等，失败步骤的半成品（如未装完的虚拟环境）会自动清理。

#### 启动服务

后端：

```bash
cd backend
source .venv/bin/activate
python -m uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

前端（启动方式不变）：

```bash
cd frontend
npm start
```

#### 手动分步执行（备选）

<details>
<summary>展开查看手动步骤</summary>

##### 后端开发

```bash
cd backend
pip install -r requirements.txt

# 配置环境变量
cp .env.example .env

# 初始化数据库
python -m app.init_data

# 启动服务
python -m uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

##### 前端开发

```bash
cd frontend
npm install

# 配置环境变量
cp .env.example .env

# 启动服务
npm start
```

</details>

### 默认账号

- 管理员: admin / admin123
- 演示用户: demo / demo123

## 项目结构

```
yel3-1/
├── backend/                    # 后端服务
│   ├── app/
│   │   ├── routers/           # API路由
│   │   │   ├── auth.py        # 认证接口
│   │   │   ├── projects.py    # 项目管理接口
│   │   │   ├── seismic.py     # 地震数据接口
│   │   │   ├── annotations.py # 标注接口
│   │   │   └── wells.py       # 井数据接口
│   │   ├── services/          # 业务服务
│   │   │   ├── cache_service.py    # 缓存服务（Redis/内存）
│   │   │   ├── seismic_processor.py # 地震数据处理
│   │   │   └── storage_service.py   # 对象存储服务
│   │   ├── models.py          # SQLAlchemy数据模型
│   │   ├── schemas.py         # Pydantic请求/响应模式
│   │   ├── auth.py            # 认证与权限控制
│   │   ├── config.py          # 配置管理
│   │   ├── database.py        # 数据库连接
│   │   ├── init_data.py       # 初始化数据脚本
│   │   ├── seed_data.py       # 示例数据脚本（幂等）
│   │   └── main.py            # 应用入口
│   ├── .env.example
│   ├── Dockerfile
│   ├── requirements.txt
│   └── start.sh
├── frontend/                   # 前端应用
│   ├── src/
│   │   ├── components/        # React组件
│   │   │   ├── Layout.tsx
│   │   │   ├── SeismicCanvas.tsx
│   │   │   ├── SliceRenderer.tsx
│   │   │   ├── VolumeRenderer.tsx
│   │   │   ├── MeasurementOverlay.tsx
│   │   │   ├── ControlPanel.tsx
│   │   │   ├── Toolbar.tsx
│   │   │   └── StatusBar.tsx
│   │   ├── pages/             # 页面组件
│   │   │   ├── Login.tsx
│   │   │   ├── Projects.tsx
│   │   │   └── Viewer.tsx
│   │   ├── store/             # Redux状态管理
│   │   │   ├── slices/
│   │   │   └── index.ts
│   │   ├── services/          # API服务
│   │   ├── types/             # TypeScript类型定义
│   │   ├── App.tsx            # 应用入口
│   │   └── index.tsx          # 渲染入口
│   ├── .env.example
│   ├── Dockerfile
│   └── package.json
├── docs/                       # 文档
│   ├── DATABASE_DESIGN.md     # 数据库设计文档
│   ├── API_REFERENCE.md       # API接口说明
│   ├── DEPLOYMENT_GUIDE.md    # 部署指南
│   └── USER_MANUAL.md         # 用户操作手册
├── scripts/                    # 开发环境脚本
│   └── dev-setup.sh           # 本地开发环境一键初始化
└── docker-compose.yml          # Docker编排配置
```

## 系统要求

### 最低配置
- CPU: 4核
- 内存: 8GB
- 存储空间: 100GB
- 浏览器: 支持WebGL 2.0

### 推荐配置（处理大规模数据）
- CPU: 16核以上
- 内存: 64GB以上
- 存储空间: SSD 1TB以上
- 浏览器: Chrome/Firefox 最新版本（支持WebGL 2.0）

## 文档

详细文档请参阅 `docs/` 目录：

- [数据库设计文档](docs/DATABASE_DESIGN.md)
- [API接口说明](docs/API_REFERENCE.md)
- [部署指南](docs/DEPLOYMENT_GUIDE.md)
- [用户操作手册](docs/USER_MANUAL.md)

## 性能优化

- **分块上传**: 支持大文件分块上传（最大10GB）
- **多级缓存**: Redis缓存热门切片数据和子体积数据，自动降级为内存缓存
- **采样统计**: 地震数据统计采用采样计算，避免全量加载
- **WebGL加速**: 利用GPU加速三维渲染和切片显示
- **缩略图生成**: 切片图像自动生成缩略图（最大512px），提升加载速度

## 许可协议

MIT License
