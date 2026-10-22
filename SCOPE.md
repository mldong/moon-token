# 范围与保证

本项目的支持范围、依赖前提与已知边界，供选型与集成时参考。

## 支持范围

| 模块 | 支持等级 | 依赖与前提 |
|---|---|---|
| `mldong/moon-token` | 核心 | 本家 `moon-token-store` 与官方 `moonbitlang/async` |
| `mldong/moon-token-store` | 核心 | 无注册表依赖 |
| `mldong/moon-token-store-file` | 核心 | 本家 store 与官方 async；同机同目录，无外部服务 |
| `mldong/moon-token-store-redis` | 扩展 | 另依赖 `oboard/redis`，需自备 Redis 5.0+ |
| `mldong/moon-token-moonback` | 扩展 | 另依赖官方 `moonbitlang/moonback` |

核心模块不引入第三方运行时，内存与文件两档不要求任何外部服务。
Redis 后端解决多实例共享会话，功能与缺陷修复跟随 `oboard/redis`；
moonback 适配绑定具体 web 框架。扩展模块的变更节奏可以独立于核心。

## 已知边界

- **授权快照首次并发取数**：快照命中时复用供数结果，未命中时取数并回填。
  同一会话的首次并发请求不做在途合并，此时供数端口可能被调用多轮；
  串行调用在首次回填后共用同一份快照。
- **权限变更的生效时机**：业务修改权限或角色后，需调用 `invalidate_grants`
  或重新登录；缓存本身不会自动感知业务库变化。
- **Redis 后端与第三方驱动**：适配层按 `oboard/redis` 的接口工作，不承诺该驱动
  在所有服务端版本上的行为；生产使用前请在你的 Redis 版本上跑
  `scripts/redis-gate.sh`。
- **SQL 后端**：存储端口已预留，尚无实现。
- **令牌形态**：不透明随机串 + 服务端会话，不提供 JWT。

## 许可与来源

Apache-2.0，见 [LICENSE](LICENSE)。

设计上参考了 [Sa-Token](https://github.com/dromara/Sa-Token)（Apache-2.0，
[许可证原文](https://github.com/dromara/Sa-Token/blob/dev/LICENSE)）的机制与语义，
范围包括双向会话映射、账号与令牌会话分层、并发登录策略、活跃时效与会话淘汰语义。
默认值、键位与数据结构由本项目按 MoonBit 的类型与效果系统重新设计，取舍记录在
[数据模型](docs/data-model.md) 的决策表中。本项目未移植、未翻译、未复制第三方代码；
Sa-Token 仅作为设计参考，与本项目许可一致，不产生额外的许可证继承义务。
