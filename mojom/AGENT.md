# AGENT — Mojom 目录

## 职责

IDL 与 IPC 契约定义：`mojom/`。

## 常用入口

- 功能服务定义：`*.mojom`

## 测试与质量

- 修改 mojom 后同步更新 `host/`、`bridge/`、`owl-client-app/` 的对应实现与测试。
- 执行 `git grep` + 构建检查确认生成代码更新正常。

## 风险约束

- IPC 合同变更须先同步版本策略与兼容说明。
- 每次变更后补充或更新至少一条端到端测试链路。
