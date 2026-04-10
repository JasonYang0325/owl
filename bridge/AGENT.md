# AGENT — Bridge 目录

## 职责

ObjC++ C-ABI 桥接层：`bridge/` 负责 Swift 与 Chromium Host 的稳定接口。

## 常用入口

- API 声明：`bridge/owl_bridge_api.h`
- 接口实现：`bridge/owl_bridge_api.cc`
- 类型定义：`bridge/owl_bridge_types.*`

## 测试与质量

- 修改前确认 ABI 前向兼容，不做未同步发布的符号更改。
- 修改桥接签名后同步更新 Mock/测试 Fixture。
- 变更后运行 `owl-client-app/scripts/run_tests.sh integration`（通过真实 Host）和 `owl-client-app/scripts/run_tests.sh unit`（快速回归）。

## 约束

- 回调线程模型必须明确：UI 事件在主线程处理。
- `OWLBridge_Initialize` 幂等性与初始化顺序需保持不变。
