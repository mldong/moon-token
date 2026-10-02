# 数据模型（定稿）

这份文档钉的是**存储形状与语义**：v2 的 Redis / SQL 后端按它读写，一旦有真实数据落进去，
改形状就等于迁移。所以现在定，比到时候改便宜得多。

三条读法：

- **契约是语义，不是物理形状**。同一份逻辑模型，Redis 可以把反查族存成一个 hash，SQL 可以拆成两张表——
  只要 §4 的权威源规则与 §5 的不变量成立，就算实现了同一份契约。
- 标 **FROZEN** 的项改了就是一次数据迁移；标 **可后补** 的项随时能加。
- §8 列出为落地这份定稿**需要改代码的项**（会改载荷形状 ⇒ 需要发新版本），未点头前不动。

## 1. 逻辑模型

```text
realm（命名空间＝每个键的前缀，不是实体、不是表）
  │
  ├─ A 账号族   1 ──────── N  T 令牌会话          A.members[].token → T.token
  │   │                        │
  │   │                        └─ 1 ── 1 ── R refresh 绑定   T.refresh ↔ R.access 互指
  │   │
  │   ├─ 1 ── 1 ── S 账号会话（跨该账号所有 token 共享）
  │   └─ 1 ── 0..1 ── D 封禁
  │
  └─ device：不是实体，只是 A 成员上的分组键（Shared 策略、按设备踢靠它）
  │
  └─ Z 活会话索引：token → 登录时刻，**无载荷、纯派生**（不是第六类记录）
      服务两件事：§7.14 的在线列表枚举、§7.11 的上限淘汰取最老
```

基数与含义：

| 关系 | 基数 | 为什么是这个 |
|---|---|---|
| `A : T` | 1 : N | `Coexist` 下同账号多设备各一枚；`Supersede`/`Shared` 只是让它趋向 1 |
| `T : R` | 1 : 1 | 一次签发一整对；**不支持一枚 refresh 换多枚 access**（要换多次就转手多次，每次都换新对） |
| `A : S` | 1 : 1 | 账号级附加态，与 token 无关 |
| `A : D` | 1 : 0..1 | 封禁是"当前有没有"的状态，不是历史流水 |
| `T : 设备` | N : 1（字符串） | 设备不注册、不存元数据 |

## 2. 五类记录的字段（含 TTL 公式）

### `T` 令牌会话 — 键 `{realm}:T:{token}`

| 字段 | 线格式键 | 类型 | 权威源？ | 说明 |
|---|---|---|---|---|
| login_id | `login` | String | 是 | **FK → `A`**；空 login_id 的记录解不开（防串键） |
| device | `dev` | String | 是 | 归一后的设备 id（空/空白 → `default`） |
| login_time | `lt` | Int64 ms | 是 | 签发时刻，之后不变 |
| expire_at | `exp` | Int64 ms | **是（唯一权威）** | 语义两态，见 §4.2；`<=0`＝不过期 |
| last_active | `la` | Int64 ms | 是 | `IdleMark` 的判据 |
| status | `st` | 0/1/2 | 是 | 0 Active / 1 Kicked / 2 Superseded |
| refresh_token | `refresh` | String | 是 | **FK → `R`** |
| extra | `extra` | Map\<String,String\> | 是 | 自由扩展，**不可检索**（§4.4）；登录来源 `ip` / `ua` 就在这里（§7.9） |

TTL 公式：活会话＝`expire_at`；落墓碑时改写为 `now + kick_grace`。

> 这张表钉的是**目标形状**，允许与当前代码不一致，但**每一处不一致都必须就地标出 §8 的编号**——
> 没标、代码里又没有的字段就是文档在撒谎。曾经列过 `ip` / `user_agent` 两行（当一等列），
> 那是 §7.9 改判前的残留、代码里从来没有、也没标编号，已删。

### `A` 反查族 — 键 `{realm}:A:{login_id}`

| 字段 | 线格式键 | 类型 | 说明 |
|---|---|---|---|
| login_id | `login` | String | **PK**；必须与键里的一致，否则整条拒读 |
| version | `ver` | Int64 | 只随成员增删单调递增；判重幂等靠它 |
| members | `members` | 数组 | 每项 `{d: device, t: token, e: expire_at, lt: login_time}`（`lt` 已于 §8.6 落地） |

TTL 公式：`max(成员 e)`；族空 ⇒ 删键。

`lt` 为什么必须在族里存一份（§7.11 的取证与取舍在这一节末尾，看 §7.11）：`max_sessions` 的淘汰
**按登录时刻先进先出**，排序依据就是登录时刻。它是**派生缓存里的排序键**——可用于筛序与淘汰定序，
不可用于裁决，权威永远是 `T` 里那份。

今天 `e` 恰好与 `lt` 同序（`e = 登录时刻 + timeout`，且 timeout 全局一个值），所以理论上可以不加 `lt`
只排 `e`。不加会踩两个坑，所以定成加：

1. **载体不保证有序**。内存版是数组（追加序免费）；SQL 侧成员表没有天然行序；Redis 侧按 §6.1 映射成
   HASH，字段无序 ⇒ 只有显式存 `lt`，三个后端才能对"谁最老"给出同一个答案（对齐不变量 6）。
2. **`e` 与登录序的等价是脆弱的**。一旦允许按次或按设备覆盖时长，`e` 升序就不再等于登录先后，
   淘汰会静默变成"短时效的先死"——一个和上限毫无关系的判据。

`lt` 只在这一条判据上承重；把它挪作他用（比如在线列表显示登录时间）是顺手，不是它的职责。

### `R` refresh 绑定 — 键 `{realm}:R:{refresh_token}`

| 字段 | 线格式键 | 说明 |
|---|---|---|
| login_id | `login` | FK → `A` |
| device_id | `dev` | 签发时设备 |
| access_token | `access` | FK → `T`；轮转时据此作废旧 access |

TTL 公式：`now + refresh_timeout`。读取方式是**原子取删**（`get_and_del`），重放防护整个压在它身上。

### `S` 账号会话 — 键 `{realm}:S:{login_id}`

| 字段 | 线格式键 | 说明 |
|---|---|---|
| login_id | `login` | **PK** |
| attrs | `attrs` | Map\<String,String\> |

TTL 公式：现版跟"族 max_expire"，族空时退化成**永不过期**——这是个泄漏，§8 要修。

### `D` 封禁 — 键 `{realm}:D:{login_id}`

| 字段 | 线格式键 | 说明 |
|---|---|---|
| until | `until` | 到期时刻 |
| reason | `reason` | 原因文本（会原样出现在错误消息里） |

TTL 公式：`until`；读路径判过期即回收（无后台任务）。

## 3. 键位字母表（预留即冻结）

| 字母 | 用途 | 状态 |
|---|---|---|
| `T` `A` `R` `S` `D` | 上面五类 | 已用 |
| `X` | 预留给"token → realm"反查索引 | **预留不实现**（§7.3） |
| `E` | 预留给持久事件/审计流水 | **预留不实现** |

预留的意义很实在：将来谁拿 `X:` 存别的东西，等真要做反查索引时就没有干净的键位可用了。
键位字母一旦进过发布版本就不可回收。

## 4. 权威源与四条硬规则

### 4.1 会话状态以 `T` 为唯一权威，`A` 只是索引

在线列表/设备列表的判活必须回查 `T`；`A.members[].e` 只用来**快速筛掉"肯定已过期"的成员**，
省掉 N 次回查。推论：

- 冗余的 `e` 漂移**不得改变对外行为**（最多导致一次多余回查）。
- 所有影响族的写必须走 `apply`（`AddToken` / `TouchExpire` / `RemoveTokens` / `MarkStatus`）。
  绕过 `apply` 直写 `T` 而不推族，就是制造漂移。
- `sweep` 负责收敛：发现成员 `e` 与对应 `T.expire_at` 不一致时，**以 `T` 为准修族**。

### 4.2 `expire_at` 一列两义（这是全模型最容易踩的地方）

| status | `expire_at` 的含义 | 读路径行为 |
|---|---|---|
| Active | 签发时效截止时刻 | 过期 ⇒ **照旧返回载荷**，让裁决报 `SessionExpired` |
| Kicked / Superseded | **保留窗截止**（＝落墓碑时 `now + kick_grace`） | 过期 ⇒ 当场回收，读作 `UnknownToken` |

不打算拆成两列（内存版语义已经跑通、测试已钉），但**每个后端实现都必须知道这个双义**：
Redis 侧 `T:` 键的 TTL 必须设到 `expire_at + kick_grace`，否则墓碑活不到窗口关，
`KickedOut` 会静默退化成 `UnknownToken`——而且**不会有任何测试变红**（内存版和后端测的是同一套语义断言，
后端少设 TTL 只在真实时间下才暴露）。

两条配套口径：

- **加窗只加在活会话上**。`MarkStatus` 传进来的到期时刻已经是"保留窗截止"，再套一次就是双份窗。
  本库把这件事收在 `TokenConfig::key_expire_at` 一个函数里，三个 `T:` 写点统一走它。
- **内存版同样要加**。不加的话惰性读有特例兜着（`lookup` 对过期活会话照旧交回载荷），
  看着没事；一旦服务显式调 `sweep`，"刚过时效"的会话就被连键删掉，对端从 `SessionExpired`
  退化成 `UnknownToken`（A29 钉这条）。

### 4.3 封禁压在会话之上

`D` 与 `T` 互不改写：封禁期间会话本身仍然有效，解禁后原 token 复活。
所以 `D` 不能做成 `T` 的一个状态位（那会让"解禁"无法恢复原会话）。

### 4.4 `extra` / `attrs` 不可检索

两个自由 map 只承担"存回去"的责任。任何需要按值查询、按值建索引的字段，都必须先成为**一等列**，
否则 v2 会被"帮我按 ip 查在线用户"这类需求逼出临时索引。
推荐（不强制、不建列）的键名：`ip`、`ua`、`entry`。

## 5. 不变量

1. `status` 只能 Active → 墓碑单向迁移，墓碑不可复活。
2. 一枚 token 只属一个族；`add_member` 判重＝幂等空操作（不推 `version`）。
3. `version` 只随成员增删单调递增；续期不推版本，`Shared` 复用同 token 把成员移回队尾也不推版本
   （成员集合没变，变的只是顺序）。
4. 族键载荷里的 `login_id` 与键里的不一致 ⇒ 整条拒读（防串键，宁可读成"无族"）。
5. `extra` 给 `None` 是删键，给 `""` 是存空串——两者不同（`''` 与"没有这个键"在业务上从来不是一回事）。
6. 补丁不带时钟：需要绝对时刻处一律传算好的 `deadline` / `expire_at` ⇒ 多后端同判据同答案。
7. 注销漏斗是单一出口：`T` 删 + 族摘 + 绑定的 `R` 联动删，三处缺一即孤儿键。

## 6. 后端物理映射

### 6.1 Redis

```text
{realm}:T:{token}    STRING(线格式 v=1，见 docs/storage-port.md)   PEXPIREAT = expire_at + kick_grace
{realm}:A:{login_id} HASH  field=token → {d,e,lt}，另置 _ver 字段   TTL = max(e)
{realm}:R:{refresh}  STRING                        PEXPIREAT = now + refresh_timeout
                                                      读＝GETDEL（或 Lua 原子取删）
{realm}:S:{login_id} HASH  attrs + _ver             TTL = 见 §8（当前公式会泄漏）
{realm}:D:{login_id} STRING                         TTL = until
{realm}:Z            ZSET   member=token, score=lt   无 TTL（靠 sweep 剔死成员）
```

`Z` 是**派生索引，不是第六类记录**——它没有载荷，只有 `(token, lt)`，权威永远在 `T`。
它同时服务两件事，所以只此一处、不分叉：

- §7.14 的在线列表：`ZREVRANGEBYSCORE` 按 `lt` 反序翻页（游标就是上一页最小的 `lt` + token，稳定）。
- §7.11 的上限淘汰：`ZRANGE 0 .. size-max` 一次拿到最老的若干枚。

写入时机：**登录 ZADD、注销/踢/顶 ZREM**；**续期不写**（否则 score 就变成活跃时刻，
把 §7.11 判据偷偷改掉，正是上一轮取证否掉的那条回写路）。`sweep` 负责收敛：成员在 `T` 里已不存在
或已判过期 ⇒ `ZREM`。索引落后于事实期间，`list_sessions` 取到的 token 会在 `get_many` 那一轮被丢弃，
所以分页可能出现"这页少几条"，不会返回错数据。

要点：族的 `expire_at` 与 `version` 落在 hash 字段上，`HSET` 天然原子；
`apply` 的多步写用 Lua 或 `MULTI/EXEC` 包；`sweep` 用 `SCAN` + 惰性判过期兜底（Redis 的 TTL 已经做了大半）。

三条后端必须守的：

- **HASH 字段无序** ⇒ 别指望映射顺序当登录序。上限淘汰（§7.11）只认成员里的 `lt`；
  嫌"取全族再应用层排"不够直白，可把族映射换成 ZSET（`member=token, score=lt`），
  淘汰就是 `ZRANGE` 取最老的 `size - max` 个——但那样 `e` 得另存，二选一，别混。
- **族的写不许退化成整块覆盖**。并发两台设备同时登录时，"读全族→改→整块 set"会互相丢成员；
  必须带 `version` 做 CAS（§8.1），失败重读重试。内存版单线程看不见这个坑。
- **活跃时间不回写族**（§7.11 取证第 2 条）：续期只动 `T` 那一族的 TTL 与载荷。

### 6.2 SQL

```sql
-- 会话：主键 (realm, token)；expire_at 建索引供 sweep
CREATE TABLE token_session (
  realm         VARCHAR(32)  NOT NULL,
  token         VARCHAR(64)  NOT NULL,
  login_id      VARCHAR(64)  NOT NULL,
  device        VARCHAR(32)  NOT NULL,
  login_time    BIGINT       NOT NULL,
  expire_at     BIGINT       NOT NULL,   -- 墓碑态下语义＝保留窗截止
  last_active   BIGINT       NOT NULL,
  status        TINYINT      NOT NULL,   -- 0 Active / 1 Kicked / 2 Superseded
  refresh_token VARCHAR(64)  NOT NULL,
  extra         TEXT         NOT NULL,   -- 线格式原串，不是 JSON 列型，见本节末
  PRIMARY KEY (realm, token),
  KEY idx_login  (realm, login_id),
  KEY idx_expire (expire_at),
  KEY idx_login_time (realm, login_time)   -- §7.14 在线列表按登录序翻页走这条
);

-- 族头 + 成员：拆两表 ⇒ SQL 侧天然没有 §4.1 的冗余（成员 join 会话取 expire_at）
CREATE TABLE account_family (
  realm VARCHAR(32) NOT NULL, login_id VARCHAR(64) NOT NULL, version BIGINT NOT NULL,
  PRIMARY KEY (realm, login_id)
);
CREATE TABLE account_family_member (
  realm VARCHAR(32) NOT NULL, login_id VARCHAR(64) NOT NULL,
  token VARCHAR(64) NOT NULL, device VARCHAR(32) NOT NULL,
  PRIMARY KEY (realm, login_id, token),
  KEY idx_token (realm, token)
);

CREATE TABLE refresh_binding (
  realm VARCHAR(32) NOT NULL, refresh_token VARCHAR(64) NOT NULL,
  login_id VARCHAR(64) NOT NULL, device VARCHAR(32) NOT NULL,
  access_token VARCHAR(64) NOT NULL, expire_at BIGINT NOT NULL,
  PRIMARY KEY (realm, refresh_token), KEY idx_access (realm, access_token)
);

CREATE TABLE account_session (
  realm VARCHAR(32) NOT NULL, login_id VARCHAR(64) NOT NULL,
  version BIGINT NOT NULL DEFAULT 0,      -- 乐观锁，见 §8
  attrs TEXT NOT NULL, expire_at BIGINT NOT NULL,   -- 同上：存线格式原串
  PRIMARY KEY (realm, login_id)
);

CREATE TABLE account_ban (
  realm VARCHAR(32) NOT NULL, login_id VARCHAR(64) NOT NULL,
  until_ms BIGINT NOT NULL, reason VARCHAR(255) NOT NULL,
  PRIMARY KEY (realm, login_id), KEY idx_until (until_ms)
);
```

`get_and_del` 在 SQL 侧＝事务里 `SELECT ... FOR UPDATE` + `DELETE`（或直接 `DELETE ... RETURNING`，
Postgres 支持、MySQL 8 不支持要走事务）。**这条是后端能力差异最大的一处**，v2 选型时要单独验。

**为什么 `extra` / `attrs` 用 `TEXT` 而不是 JSON 列型**（四条，一条比一条硬）：

1. 载荷里存的本来就是线格式原串（`v=1|k=v|…`，键与值都转义，见 `docs/storage-port.md`），不是 JSON。
   用 JSON 列型等于要求"先另转一种序列化再落库"⇒ 解码出现第二条路，而它只该有 `SessionRecord::decode` 这一条。
2. 各家 JSON 行为不一致：MySQL 的 JSON 列会校验并规范化、且不能带默认值；Postgres 的 `jsonb` 会重排键、
   `json` 保留原文；SQL Server 长期只能 `NVARCHAR` + `ISJSON` 约束（新近版本才引入自己的 json 型，语义又不同）。
   同一份 DDL 想在多种库上跑，就别把类型语义交给库去解释。
3. 更要紧的：JSON 列型会**诱使后人去建 JSON／表达式索引**，那正好违反 §4.4"extra 不可检索"。
   列型本身就是这道红线的物理护栏——存成文本，想"顺手按 ip 查"就没有免费的路可走。
4. 尺寸口径：`TEXT` 上限 64KB，装展示字段绰绰有余；真需要大对象是业务表的活，**不靠升列型解决**。

SQL 侧**不需要**Redis 那个 `Z` 结构：`token_session` 本身就是全量 enumerable 的表，
`idx_login_time` 直接支撑 §7.14 的按登录序翻页；`list_sessions` 在 SQL 后端就是一条带游标的 range 查询，
`get_many` 是一条 `IN (?)`。两个后端的差别留在适配器里，不渗进契约。

## 7. 定稿决策清单

| # | 决策 | 结论 | 可逆性 |
|---|---|---|---|
| 7.1 | 族成员要不要冗余 `expire_at` | **要**，但降级为派生缓存：只用于筛除、不用于裁决；`sweep` 负责以 `T` 为准收敛 | 可后补（不改形状） |
| 7.2 | `expire_at` 一列两义要不要拆 | **不拆**，但写进契约并作为后端验收项（Redis 必须 `+kick_grace`） | 拆＝迁移，现在不拆 |
| 7.3 | 要不要 `token → realm` 反查 | **v2 不做**，但**预留 `X:` 键位**。理由：多写一键＋多一份一致性，而网关场景可用"按配置逐个 realm 试"解决 | 预留即冻结 |
| 7.4 | `extra` 能不能建索引 | **不能**（§4.4）。机理不变：要按值查就得升一等列。但按 §7.9 的改判，**本库不替业务预测哪些字段该升列**——按 ip／用户名检索这类需求由业务侧用自己的表解决；鉴权库只保证 `list_sessions` 能枚举、`get_many` 能把 `extra` 原样带出 | 可后补 |
| 7.5 | refresh 与 access 是否 1:1 | **是**，不做"一枚 refresh 换多枚 access" | 改＝迁移 |
| 7.6 | 封禁要不要作用域字段 | **不加** `scope`（realm 前缀已是作用域）；设备级封禁＝用 `kickout` | — |
| 7.7 | 事件/审计要不要落库 | v1 **不落**（listener 是内存回调），预留 `E:` 键位 | 预留即冻结 |
| 7.8 | 权限快照（审计"当时授予了什么"） | **不做**。权限每次现查 SPI，库里不留副本；要审计就在业务侧自己落流水 | — |
| 7.9 | 登录来源 ip / ua | **不升一等列**（10-02 改判，撤销我先前"要能检索就得建列"的定法）。它们和 `userName` / `realName` 一样属**业务口**：业务在登录时塞进 `extra`，我们只负责带回去显示，不解释、不建索引 | 因为从未实现，撤销零成本 |
| 7.14 | 在线用户列表的检索面 | **要有，但不是 scan**。定三件：① 端口加 `list_sessions(filter, cursor, limit)`，条件只开放**我们建模的精确字段**（`login_id` / `device`），**不给 status 档**（判活是取详情那一轮的事，索引不裁决）、不给模糊匹配、不暴露裸扫描，`limit` 有服务端上限（100）；② 同时加 `get_many(keys)`，让"取一页详情"是一次批量往返而不是 N 次；③ 排序＝**登录时刻反序**（最新在前），游标也按 `lt` 走，这样翻页稳定、且 §7.11 的"取最老 N-上限 条"淘汰共用同一个索引 | 端口方法一旦进发布版本，实现方就得全部提供 ⇒ 现在就定 |

> **7.14 的验收条件不是设想出来的**，是拿 mldong 快速开发框架的在线用户功能读出来的（`UserServiceImpl.onlineUserList`）：
> 它现在靠"枚举全部会话键 → 逐会话读 → 逐 token 再读一块展示数据"完成，**总读次数 = 1 + N + ΣM，且没有分页**。
> 我们把它拆成 `list_sessions`（拿一页的 token 与 `lt`）+ `get_many`（只取这一页的载荷），
> 两次往返换一页 ⇒ 检索面齐了，但没有把那个 `1+N+ΣM` 的形状继承进来。
> 两条口径顺带钉住：展示字段（`userName`/`realName`/`ip`/`ua`）从载荷的 `extra` 里带出，我们不解释（§4.4）；
> 被封禁的账号**照常出现在列表里**（§4.3 封禁压在会话之上），要"封禁即不在线"由业务侧过滤或补一次注销。
| 7.10 | 多租户 / org 维度 | **不考虑**。`realm` 是唯一隔离层级；将来真要按租户再切一刀，键位变成 `{realm}:{org}:T:...` | 改＝全量迁移，所以现在就写明不做 |
| 7.11 | 同账号会话上限 | 配置 `max_sessions`，**默认 12，`-1`＝不限**；超限**按登录时刻先进先出**注销最早的（**不是**按活跃，判据取证见下方 §7.11 取证）⇒ 族成员必须带 `lt`（§2）。计数是**跨设备一条队**（总共 12 条），不是每设备 12 条。**"登录时刻"记的是最近一次登录动作**：`Shared` 复用同一枚 token 重新登录也要刷新 `lt` 并移回队尾，否则天天用的那台会被当成最老的先剔掉 | 配置默认值可商量；`lt` 一旦有数据就是形状 |
| 7.12 | 超限那一枚怎么"下线" | 配置 `overflow_exit`，三档：`Logout`（删键，对方读作 `UnknownToken`）/ `Kick`（墓碑 `KickedOut`）/ `Supersede`（墓碑 `SupersededByLogin`），**默认 `Logout`** | 默认值可后改 |
| 7.13 | refresh 可否重复使用 | **严格一次性**。不给"网络重试同一 refresh 仍返回同一新对"留窗口：重放防护优先于粗糙客户端的容错 | 改＝语义变更 |

> **7.11 / 7.12 的取证**：默认值 12（`-1` 不限）、"超过上限后主动注销第一个登录的会话（先进先出）"、
> 以及"超限那一枚以何种方式下线"是独立一档（三档：直接注销 / 踢下线 / 顶下线），取自同类生态既有实现的
> 源码与官方文档（原文常量名与逐字引文记在 hub 侧内部档案，不进公开文档与本库注释——本库不依赖那个库，
> 只采纳这套已被验证过的口径）。对应到本库：`Coexist` 与 `Shared` **都会**碰上限——`Shared` 是
> "每设备一枚"而不是全局一枚，设备数一样能把族撑爆（A23 就是钉这条的）；只有 `Supersede` 碰不到，
> 它每次把全部旧会话清空、活成员恒为 1，所以上限那一路对它显式跳过（D13）。
>
> **为什么判据是登录时刻而不是活跃时刻——这是键布局决定的，不是口味**。读那个实现的数据结构可以看清：
> 它的登录态只有三族键，`token → loginId`（认证热路径只读这一族）、`last-active:{token}`（活跃时间戳，
> 独立一族）、`session:{loginId}`（账号会话，**成员表内嵌在同一个序列化的值里**）。于是：
>
> 1. **登录序免费，活跃序要 N 次往返**。登录序就是成员数组的下标（新登录 append 到尾部 + 单调递增序号），
>    淘汰＝一次读拿到全族 + 从头数 `size - 上限` 个。而活跃时刻住在**另一族独立键**里，要按活跃淘汰就得
>    对族里每个 token 各读一次。
> 2. **它宁可多开一族键，也不把活跃写回账号会话**。因为账号会话是整块值，每请求写回＝重写"含全部成员"的
>    一块，写放大 O(成员数)/请求。这条直接否掉"按活跃就把活跃时间顺手回填族"的做法。
> 3. **成员记录里确实存了登录时间戳，但淘汰路径一次都没读它**（读的是下标）——时间戳是留给在线列表显示的。
>
> 结论搬到本库：淘汰判据＝**登录时刻**；活跃只管"这条会不会过期"，永远不参与"谁被淘汰"。
> 差别在载体：本库的族按 §6.1 映射成 Redis HASH、按 §6.2 拆成 SQL 成员表，两者都**没有下标这条免费午餐**，
> 所以登录时刻必须显式存成 `lt`（§2）。

## 8. 为落地这份定稿需要改代码的项

8.1–8.4、8.6–8.10 已于 2026-10-02 全部落地（owner 点名"动"、"继续"）。8.1–8.4、8.6–8.7 是
**载荷形状或 TTL 语义**的改动 ⇒ 一旦有真实数据就是迁移，所以趁 v2 之前做最便宜；
8.8 是**端口方法**的增补（不动已有载荷，但每个实现方都得补上）；8.9/8.10 是实现过程中才看清的两条，
都改了行为。

| # | 改什么 | 为什么必须现在定 | 状态 |
|---|---|---|---|
| 8.1 | `S` 账号会话加 `version`（乐观锁），TTL 改成"族最晚到期"与"本次写刷新的 `refresh_timeout` 下限"取更晚者 | 读-改-写会丢更新；旧公式在族空时退化成 `max_expire()=0`＝永不过期＝泄漏 | **done**（A27 断言 31 天后读不到） |
| 8.2 | `D` 封禁加 `operator` 与 `created_at`；`disable` 加 `operator?` 可选参 | 审计要"谁封的、什么时候封的"，等上线再补就是给已有行留 NULL | **done**（A28；老写法不传照样解出空串） |
| 8.3 | `sweep` 做族↔会话一致性收敛：成员 `e` 与 `T.expire_at` 不一致以 `T` 为准修，`T` 没了就摘成员 | §4.1 的"派生缓存"定位要有兑现机制，否则它就是个说法 | **done**（修正 `e` 不推版本，只有增删推） |
| 8.4 | 键位字母 `X:` / `E:` / `Z` 写进 `KeySpace` 预留注释 + 后端实现验收清单 | 预留与验收项不写下来，第一个后端就会漏 | **done**（注释在 `patch.mbt`，清单进 `docs/storage-port.md`） |
| 8.5 | ~~`T` 加 `ip` / `ua` 两列~~ **撤销**（§7.9 改判：属业务口，走 `extra`） | — | 零改动（从未实现） |
| 8.6 | `A.members[]` 加 `lt`（登录时刻） | 淘汰按登录时刻定序，而 Redis HASH 与 SQL 成员表都不保序 | **done**（A24 含"旧串缺 `lt` 解出 0"的兼容断言） |
| 8.7 | `TokenConfig` 加 `max_sessions`（默认 12，`-1` 不限）与 `overflow_exit`（默认 `Logout`）；`decide_concurrent` 增"超限按 `lt` 升序剔最老"分支；新增 `FamilyPatch::ForgetTokens` 让 Kick/Supersede 档"留墓碑但摘成员" | 没有上限，脚本刷登录会让族无限增长；不摘成员则保留窗内的墓碑会被下次登录重数进上限 | **done**（D11–D13 纯函数 + A21–A23 三档端到端） |
| 8.8 | 端口加 `list_sessions(filter, cursor, limit)` 与 `get_many(keys)`；应用层开 `list_online` / `load_online`；内存版遍历自有表，Redis 版走 §6.1 的 `Z`，SQL 版走 `(realm, login_time)` 索引 | §7.14：mldong 的在线用户功能要能把人查出来，旧的六法一个账号都不认识 | **done**（A25–A26；**实现方破坏性变更**：trait 多两法） |
| 8.9 | `sweep` 与 §4.2 的冲突：内存版 `T:` 键原先按 `expire_at` 存 TTL，一次显式 `sweep` 会把"刚过时效、本该报 `SessionExpired`"的活会话连键删掉，对端读成 `UnknownToken` | 惰性读路径有特例兜着，所以只有跑 `sweep` 的服务会踩——最难查的那种 | **done**（`TokenConfig::key_expire_at` 在三个 `T:` 写点统一加保留窗；A29 钉住） |
| 8.10 | `Shared` 复用同一枚 token 时刷新 `lt` 并把成员移回队尾（新增 `FamilyPatch::RefreshLogin`） | 不刷新的话，一台天天复登的老设备在先进先出里永远排最前、会被上限先剔掉——与参照系语义相反 | **done**（A30 钉住；移动位置**不推**版本号） |

**发版那一轮要一起做的三条"假绿窗口"——已随 0.1.1 闭掉**（0.1.1 上 mooncakes 之后，
`docs-check.sh` 的 `moon add` 自动解析到新代次，旧形状当场变红，正是预期的行为）：

1. §9 的族记录快照：`FamilyMember::make` 三参 → 四参，并补一条 `login_time` 往返断言
   （它现在真的在钉 `lt` 这个键名，而不只是钉旧形状）。
2. `docs/configuration.md` §5 与 `docs/session-management.md` §7 的示例：从 `text` 围栏转成
   `moonbit` 可跑块——上限那一段现在会真跑一次"签第三枚、最早那枚已不在线"。
3. `docs/storage-port.md` §2 的 `CountingStore` 装饰示例补齐两个读侧方法（八个全转发）。
   **转换时门禁又抓出第四处**：`docs/testing.md` 里还有一个同名的装饰示例，原清单没列它——
   它测的是"写了几次"，所以两个新方法照转发但**不计进 `writes`**，否则节流那页的断言会被带偏。

**下一轮（0.1.2）要一起做的一条**：`core/guard` 的 `run_guard` 豁免分支原先返回 `Ok(path)`，
已改成 `Ok(GuardOutcome)`（`Exempt` / `Passed(login_id)`）。发版后把 `docs/route-guard.md` §1
那段快照（现在断言 `r[2] == "/api/public/ping"`）改成两臂匹配，并删掉那里"下一版会改掉它"的
`text` 围栏。

## 9. 这份模型被什么钉住（可复跑）

```moonbit
test "线格式字段名是契约：改名即迁移" {
  let session = @port.SessionRecord::make("u1", @port.Device::of("pc"), 1000L, 9000L)
  session.refresh_token = "rt-1"
  session.extra["ip"] = "10.0.0.1"
  let back = @port.SessionRecord::decode(session.encode())
  match back {
    None => fail("会话记录往返失败")
    Some(r) => {
      assert_eq(r.login_id, "u1")
      assert_eq(r.device.id, "pc")
      assert_eq(r.login_time, 1000L)
      assert_eq(r.expire_at, 9000L)
      assert_eq(r.last_active, 1000L)
      assert_eq(r.status.to_code(), "0")
      assert_eq(r.refresh_token, "rt-1")
      assert_eq(r.extra["ip"], "10.0.0.1")
    }
  }
}

test "族记录往返保形状；键位串了必须拒读" {
  let fam = @port.FamilyRecord::empty("u1")
  fam.members.push(
    @port.FamilyMember::make(@port.Device::of("pc"), "tok-1", 9000L, 1234L)
  )
  fam.version += 1L
  let blob = fam.encode()
  match @port.FamilyRecord::decode(blob) {
    None => fail("族记录往返失败")
    Some(r) => {
      assert_eq(r.login_id, "u1")
      assert_eq(r.version, 1L)
      assert_eq(r.members.length(), 1)
      assert_eq(r.members[0].device.id, "pc")
      assert_eq(r.members[0].login_time, 1234L)   // lt 是上限淘汰的排序键，必须能往返
    }
  }
  // 域层的守卫：键里的 login_id 与载荷里的不一致 ⇒ 整条拒读（宁可读成"无族"）
  assert_true(@domain.AccountFamily::parse("someone-else", blob) is None)
}
```

字段名早已被核心模块里的既有用例钉住（`store/port` 的往返用例、`core/policy` 的 D10），改一个字母就红；
上面这两条是同一判据在文档层的复现——**文档与代码必须同时改，不许单方面迁就一边**。

上面第二条用到域层的 `AccountFamily::parse`，说明文档工程连 `domain` 包都真引得到——`scripts/docs-check.sh` 是按代码里出现的 `@别名.` 现算 import 的，所以文档写错包名也会被抓出来。
