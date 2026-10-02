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
| extra | `extra` | Map\<String,String\> | 是 | 自由扩展，**不可检索**（§4.4） |

TTL 公式：活会话＝`expire_at`；落墓碑时改写为 `now + kick_grace`。

### `A` 反查族 — 键 `{realm}:A:{login_id}`

| 字段 | 线格式键 | 类型 | 说明 |
|---|---|---|---|
| login_id | `login` | String | **PK**；必须与键里的一致，否则整条拒读 |
| version | `ver` | Int64 | 只随成员增删单调递增；判重幂等靠它 |
| members | `members` | 数组 | 每项 `{d: device, t: token, e: expire_at}` |

TTL 公式：`max(成员 e)`；族空 ⇒ 删键。

成员里的 `e` 是**派生缓存**（不是权威源），定位见 §4.1。

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
3. `version` 只随成员增删单调递增；续期不推版本。
4. 族键载荷里的 `login_id` 与键里的不一致 ⇒ 整条拒读（防串键，宁可读成"无族"）。
5. `extra` 给 `None` 是删键，给 `""` 是存空串——两者不同（`''` 与"没有这个键"在业务上从来不是一回事）。
6. 补丁不带时钟：需要绝对时刻处一律传算好的 `deadline` / `expire_at` ⇒ 多后端同判据同答案。
7. 注销漏斗是单一出口：`T` 删 + 族摘 + 绑定的 `R` 联动删，三处缺一即孤儿键。

## 6. 后端物理映射

### 6.1 Redis

```text
{realm}:T:{token}    STRING(JSON 或 v=1 线格式)   PEXPIREAT = expire_at + kick_grace
{realm}:A:{login_id} HASH  field=token → {d,e}，另置 _ver 字段   TTL = max(e)
{realm}:R:{refresh}  STRING                        PEXPIREAT = now + refresh_timeout
                                                      读＝GETDEL（或 Lua 原子取删）
{realm}:S:{login_id} HASH  attrs + _ver             TTL = 见 §8（当前公式会泄漏）
{realm}:D:{login_id} STRING                         TTL = until
```

要点：族的 `expire_at` 与 `version` 落在 hash 字段上，`HSET` 天然原子；
`apply` 的多步写用 Lua 或 `MULTI/EXEC` 包；`sweep` 用 `SCAN` + 惰性判过期兜底（Redis 的 TTL 已经做了大半）。

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
  extra         JSON         NOT NULL,
  PRIMARY KEY (realm, token),
  KEY idx_login  (realm, login_id),
  KEY idx_expire (expire_at)
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
  attrs JSON NOT NULL, expire_at BIGINT NOT NULL,
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

## 7. 定稿决策清单

| # | 决策 | 结论 | 可逆性 |
|---|---|---|---|
| 7.1 | 族成员要不要冗余 `expire_at` | **要**，但降级为派生缓存：只用于筛除、不用于裁决；`sweep` 负责以 `T` 为准收敛 | 可后补（不改形状） |
| 7.2 | `expire_at` 一列两义要不要拆 | **不拆**，但写进契约并作为后端验收项（Redis 必须 `+kick_grace`） | 拆＝迁移，现在不拆 |
| 7.3 | 要不要 `token → realm` 反查 | **v2 不做**，但**预留 `X:` 键位**。理由：多写一键＋多一份一致性，而网关场景可用"按配置逐个 realm 试"解决 | 预留即冻结 |
| 7.4 | `extra` 能不能建索引 | **不能**（§4.4）。要检索就升为一等列 | 可后补 |
| 7.5 | refresh 与 access 是否 1:1 | **是**，不做"一枚 refresh 换多枚 access" | 改＝迁移 |
| 7.6 | 封禁要不要作用域字段 | **不加** `scope`（realm 前缀已是作用域）；设备级封禁＝用 `kickout` | — |
| 7.7 | 事件/审计要不要落库 | v1 **不落**（listener 是内存回调），预留 `E:` 键位 | 预留即冻结 |

## 8. 为落地这份定稿需要改代码的四项

都是**载荷形状或 TTL 语义**的改动 ⇒ 一旦有真实数据就是迁移，所以**趁 v2 之前**做最便宜。
需要你点头，未点头我不动代码。

| # | 改什么 | 为什么必须现在定 | 影响 |
|---|---|---|---|
| 8.1 | `S` 账号会话加 `version`（乐观锁），并把 TTL 公式改成"每次写刷新 `refresh_timeout`" | 现在读-改-写会丢更新；内存版单线程看不见，Redis/SQL 一定撞。TTL 现公式在族空时退化成永不过期＝泄漏 | `AccountSessionRecord` 加字段（安全）+ 一处写路径 |
| 8.2 | `D` 封禁加 `operator` 与 `created_at` | 审计要"谁封的、什么时候封的"。现在只有 `until + reason`，等真上线了再补就是给已有封禁行留 NULL | `BanRecord` 加字段（安全）+ `disable` 签名加可选参 |
| 8.3 | `sweep` 增加族↔会话一致性收敛（成员 `e` 与 `T.expire_at` 不一致时以 `T` 为准修族） | §4.1 的"派生缓存"定位要有兑现机制，否则它就是个说法 | 只改适配器，不动契约 |
| 8.4 | 键位字母 `X:` / `E:` 写进 `KeySpace` 的预留注释 + 一份"后端实现验收清单"（含 §4.2 的 Redis TTL 那条） | 预留与验收项不写下来，第一个后端就会漏 | 注释与文档，零行为变更 |

8.1 与 8.2 是**加字段**——线格式解码按键取，旧数据解出来走默认值，所以向后兼容；
但**反向不兼容**（新数据被 0.1.0 读会丢这两个字段），所以发版顺序要按"store 先、core 后、版本号前进"走。

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
  fam.members.push(@port.FamilyMember::make(@port.Device::of("pc"), "tok-1", 9000L))
  fam.version += 1L
  let blob = fam.encode()
  match @port.FamilyRecord::decode(blob) {
    None => fail("族记录往返失败")
    Some(r) => {
      assert_eq(r.login_id, "u1")
      assert_eq(r.version, 1L)
      assert_eq(r.members.length(), 1)
      assert_eq(r.members[0].device.id, "pc")
    }
  }
  // 域层的守卫：键里的 login_id 与载荷里的不一致 ⇒ 整条拒读（宁可读成"无族"）
  assert_true(@domain.AccountFamily::parse("someone-else", blob) is None)
}
```

字段名早已被核心模块里的既有用例钉住（`store/port` 的往返用例、`core/policy` 的 D10），改一个字母就红；
上面这两条是同一判据在文档层的复现——**文档与代码必须同时改，不许单方面迁就一边**。

上面第二条用到域层的 `AccountFamily::parse`，说明文档工程连 `domain` 包都真引得到——`scripts/docs-check.sh` 是按代码里出现的 `@别名.` 现算 import 的，所以文档写错包名也会被抓出来。
