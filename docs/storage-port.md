# 存储端口

`TokenStore` 是本库唯一的写入口。它是一份 **async trait**，本模块不 import 任何运行时——
所以"契约 async-first"这件事零成本，v2 的 Redis / SQL 后端可以直接实现同一个 trait。

本页代码块由 `scripts/docs-check.sh` 逐块真编译真跑（对注册表已发布件）。

## 1. 八个方法

契约形状长这样（`store/port/store.mbt`，此处只列签名，说明"谁在什么时候调"）：

```text
pub(open) trait TokenStore {
  async fn get(Self, String) -> String? raise TokenError
  async fn set(Self, String, String, Int64) -> Unit raise TokenError
  async fn del(Self, Array[String]) -> Unit raise TokenError
  async fn get_and_del(Self, String) -> String? raise TokenError
  async fn apply(Self, FamilyPatch) -> Unit raise TokenError
  async fn sweep(Self, Int64) -> Int raise TokenError
  async fn get_many(Self, Array[String]) -> Array[(String, String?)] raise TokenError
  async fn list_sessions(Self, SessionFilter, String, Int) -> SessionPage raise TokenError
}
```

后两个是本轮为"在线用户列表"补的读侧方法（决策见 `docs/data-model.md` §7.14）：
`get_many` 把"取一页详情"压成一次批量往返，`list_sessions` 只**枚举我们建模的精确条件**
（`login_id` / `device`）、按登录时刻反序、游标翻页、`limit` 有服务端上限。
**故意没有** `scan(prefix)` 之类的裸扫描，也没有模糊匹配：鉴权库里开一条全库扫的路，
等于送业务方一个 DoS 入口，也送后人一个"顺手给 extra 建索引"的借口。

后端失败一律投到共享内核的 `@port.Store(msg)` 这一档（`TokenError` 的变体之一），
**不要另立错误类型**——否则错误词汇表会在端口边界断掉，`err.message()` 就接不上了。

## 2. 一个能跑的实现：包一层计数

写后端不需要读懂库的内部——把 `MemoryStore` 委托起来、加一层观测就够了。
这也是"端口能被第三方装饰"的证明。

```moonbit
pub(all) struct CountingStore {
  inner : @mem.MemoryStore
  mut reads : Int
  mut writes : Int
}

pub fn CountingStore::new(realm : String) -> CountingStore {
  let s : CountingStore = { inner: @mem.MemoryStore::new(realm), reads: 0, writes: 0 }
  s
}

pub impl @port.TokenStore for CountingStore with fn get(self, key) {
  self.reads += 1
  self.inner.get(key)
}

pub impl @port.TokenStore for CountingStore with fn set(self, key, payload, expire_at) {
  self.writes += 1
  self.inner.set(key, payload, expire_at)
}

pub impl @port.TokenStore for CountingStore with fn del(self, keys) {
  self.writes += 1
  self.inner.del(keys)
}

pub impl @port.TokenStore for CountingStore with fn get_and_del(self, key) {
  self.writes += 1
  self.inner.get_and_del(key)
}

pub impl @port.TokenStore for CountingStore with fn apply(self, patch) {
  self.writes += 1
  self.inner.apply(patch)
}

pub impl @port.TokenStore for CountingStore with fn sweep(self, now) {
  self.inner.sweep(now)
}

pub extend CountingStore with @port.TokenStore::{
  get,
  set,
  del,
  get_and_del,
  apply,
  sweep,
}
```

三处形状必须照做（都是编译器教的）：

- **实现头不写 `async`**：`async` 由 trait 声明决定，实现体天然可 await。
- **要改的字段在结构体定义里标 `mut`**（`mut reads : Int`）。绑定用 `let` 就够——
  结构体是引用语义，`let s = ...` 之后照样能改字段。
- **`pub extend ... with ...` 不能省**：否则点号调用报 `implicit_impl_as_method`。

```moonbit
pub(all) struct P {
  permissions : Array[String]
  roles : Array[String]
}

pub impl @port.PermissionProvider for P with fn get_permissions(self, _login_id, _device) {
  self.permissions
}

pub impl @port.PermissionProvider for P with fn get_roles(self, _login_id, _device) {
  self.roles
}

pub extend P with @port.PermissionProvider::{get_permissions, get_roles}

async fn write_count_shape() -> (Int, Int) raise {
  let store = CountingStore::new("user")
  let p : P = { permissions: [], roles: [] }
  let a = @app.TokenAuth::new("user", @app.TokenConfig::default(), store, p, @style.opaque_style())
  let t = a.login("u1", device="pc")
  let after_login = (store.writes, store.reads)
  a.check_login(t.token) |> ignore
  // 续期节流窗内：不该有第二次写
  (after_login.0, store.writes)
}

async test "登录写三处；窗内再读一次不多写" {
  let (writes_after_login, writes_after_read) = write_count_shape()
  assert_true(writes_after_login >= 3)
  assert_eq(writes_after_login, writes_after_read)
}
```

## 3. `FamilyPatch`：意图补丁，不是 setter

反向索引（`A:` 族与 `T:` 状态）**只能**通过 `apply` 改。原因是"先 get 再 set"换后端就不是原子的。

| 变体 | 载荷 | 语义 |
|---|---|---|
| `AddToken` | login_id, device, token, expire_at | 族里加成员（已在则不动版本号＝幂等） |
| `MarkStatus` | tokens, status, deadline | 落墓碑并改写到期时刻——"被踢方拿到精确原因"靠它 |
| `RemoveTokens` | login_id, tokens | 摘成员 + 删 `T:` 键 |
| `TouchExpire` | tokens, expire_at | 续期：只前推到期点 |
| `PutRecord` | key, payload, expire_at | 附加数据直写（`S:` / `D:` / `R:`） |
| `RemoveKeys` | keys | 删任意键 |

契约三条：同一批按序生效；**整体幂等**（重复投递结果一致，版本号只随成员增删变化）；
不带时钟——需要绝对时刻的地方一律传算好的 `deadline` / `expire_at`，这样多后端同判据同答案。

```moonbit
async fn patch_is_idempotent() -> Bool raise {
  let store = CountingStore::new("idem")
  let patch = @port.AddToken("u9", @port.Device::of("pc"), "tok-fixed", 9_000L)
  store.apply(patch)
  let v1 = store.inner.load_family("u9").version
  store.apply(patch)
  store.inner.load_family("u9").version == v1
}

async test "同一个补丁投两次，版本号不动" {
  assert_true(patch_is_idempotent())
}
```

## 4. 惰性过期分两档：**这是契约，不是实现细节**

`get` 遇到已过期的键，不能一刀切"当作不存在"。内存档的做法是：

- 载荷是 **Active 会话**、只是过了签发时效 ⇒ **照旧返回载荷**。
  为的是让裁决层能报 `SessionExpired`。如果这里就吞掉，"过期"和"无效"会塌成同一个原因，
  本库的核心卖点当场失效，而且**不会有任何测试变红**——除非有人专门钉它（钉了：A4/A7 两条用例）。
- 载荷是**墓碑**（`Kicked` / `Superseded`）且已过保留宽窗 ⇒ 当场回收，读作 `UnknownToken`。

写自己的后端时这两档都要实现。Redis 侧靠 TTL 天然做到第二档，第一档要额外处理：
`T:` 键的 TTL 建议设成 `expire_at + kick_grace`，让"过期但还在"这个窗口真实存在，
读出来后再由裁决层判。

## 5. 键位与线格式

```text
{realm}:T:{token}        会话记录        线格式 v=1：k=v|k=v，键值都转义
{realm}:A:{login_id}     反查族          成员各自是编码后的记录，';' 连接；成员带 lt（登录时刻）
{realm}:R:{refresh}      refresh 绑定    login_id + device + 绑定的 access
{realm}:S:{login_id}     账号会话        属性表 + version（乐观锁）
{realm}:D:{login_id}     封禁            until + reason + op + at
{realm}:Z                活会话索引      member=token, score=lt；无载荷，Redis 版才需要建
```

`X:`（token→realm 反查）与 `E:`（事件/审计流水）是**预留字母**，现在不实现也不许占用——
键位一旦进过发布版本就不可回收。

线格式由共享内核持有（`store/port/codec.mbt`），适配器与领域层共用同一份编解码，
所以不会出现"两实现各自发明字段名"。加字段是安全的（解码按键取，不认识的可忽略）；
**改字段名不是**——那会让旧数据解不开，需要版本号迁移。

```moonbit
test "线格式能扛住分隔符与中文" {
  let payload = @port.encode_record([
    ("login", "张三|带竖线"),
    ("reason", "a=b&c;d"),
  ])
  let back = @port.decode_record(payload)
  match back {
    None => fail("往返失败")
    Some(fields) => {
      assert_eq(fields["login"], "张三|带竖线")
      assert_eq(fields["reason"], "a=b&c;d")
    }
  }
}
```

## 6. 换后端的最小清单（验收项，缺一条就不算实现完）

1. 实现八个 async 方法，抛错一律 `raise @port.Store(msg)`。
2. `get` 的惰性过期按 §4 两档实现。
3. `get_and_del` 必须原子（Redis：`GETDEL` 或 Lua；SQL：事务里 `SELECT ... FOR UPDATE` + `DELETE`）。
4. `apply` 里每个变体都要幂等（重复投递不重复加成员、不重复推版本号）。
   变体 `ForgetTokens` 与 `RemoveTokens` 的差别**只有留不留 `T:` 键**——上限的 Kick/Supersede 档靠它。
5. `sweep` 返回**真实**清掉的条数——用它断言"跑一万次登录登出，键数不单调增长"。
6. 键前缀照 §5，realm 拼在最前面，别自己发明分隔符。
7. **`T:` 键的 TTL 必须设到 `expire_at + kick_grace`**（`docs/data-model.md` §4.2）。少设了，
   `KickedOut` / `SupersededByLogin` 会静默退化成 `UnknownToken`，而且**不会有任何测试变红**——
   内存版与后端测的是同一套语义断言，只有真实时间下才暴露。
8. **族的写不许退化成整块覆盖**。两台设备并发登录时"读全族→改→整块 set"会互相丢成员；
   必须带 `version` 做 CAS（`FamilyRecord.version` / `AccountSessionRecord.version`），失败重读重试。
9. **序列化只有一条路**：载荷一律走共享内核的线格式（`v=1|k=v|…`，键与值都转义），
   不在后端里另起 JSON。解码只按键取，缺字段走默认值（旧数据因此天然可读）。
10. `list_sessions` 的**排序与游标必须与登录时刻一致**（新在前，同刻按 token 兜底）。
    内存版可以直接遍历自有表，Redis 版走 §6.1 那条 `Z`（`score=lt`），SQL 版走 `(realm, login_time)` 索引——
    三个后端对同一批数据必须给出同一个页序，否则游标会漂、翻页会重漏。
11. `get_many` 返回顺序与入参一致、缺失项 `None`；**不要**在这里判活以外的裁决
    （索引是派生缓存，权威在 `T:`）。
