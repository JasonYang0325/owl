# AGENT — Client 目录

## 职责

客户端 ObjC++ 适配与 Chromium Browser/Content 交互组件，承上启下于 bridge 与 host。

## 常用入口

- 客户端组件：`client/` 下的 Session、Input、Tab、生命周期相关实现。

## 测试与质量

- 核心逻辑优先补充 C++ 单测（GTest）。
- 优先验证跨层调用序列在 `host/` 与 `bridge/` 间能完成。
- 变更后执行：`owl-client-app/scripts/run_tests.sh cpp`。

## 风险约束

- 保持与 host 侧状态机一致：不要在 client 引入不透明状态副本。
