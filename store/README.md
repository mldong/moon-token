# moon-token-store

[`mldong/moon-token`](https://mooncakes.io/docs/mldong/moon-token) 的**存储契约 + 共享内核 + 内存适配器**。
独立成模块的用意不变：**加后端不必迫使核心重发**（同 jeeflow 的 core / persist / repository-mysql 分层）。

内容三块：

| 包 | 装什么 |
|---|---|
| `port` | `TokenStore`（async trait）、`PermissionProvider`、意图补丁 `FamilyPatch`、键位 `KeySpace`、值对象（`Duration` / `Device` / `SessionStatus` / `ConcurrentPolicy` / `RenewalMode` / `MatchMode`）、错误词汇表 `TokenError`、五种记录的线格式编解码 |
| `memory` | `MemoryStore`——v1 唯一交付的后端（惰性过期两档、族清扫、`sweep`） |
| — | 时钟槽 `set_clock` / `now_ms`（可注入，时效类用例靠它） |

```bash
moon add mldong/moon-token          # 核心已依赖本包，通常无需单独加
# 只想要契约/内存适配器（例如你在写自己的应用层）时：
moon add mldong/moon-token-store
```

## 直接用内存适配器

```moonbit
fn store() -> @mem.MemoryStore {
  @mem.MemoryStore::new("user")
}

async fn put_and_read() -> String? raise {
  let s = store()
  let record = @port.SessionRecord::make("u1", @port.Device::of("pc"), 1000L, 9_000L)
  s.set("user:T:tok-1", record.encode(), 9_000L)
  match s.get("user:T:tok-1") {
    None => None
    Some(payload) => (@port.SessionRecord::decode(payload)).map(r => r.login_id)
  }
}

async test "写入的会话记录能原样解回来" {
  assert_eq(put_and_read(), Some("u1"))
}
```

## 换后端要实现什么

```text
pub(open) trait TokenStore {
  async fn get(Self, String) -> String? raise TokenError
  async fn set(Self, String, String, Int64) -> Unit raise TokenError
  async fn del(Self, Array[String]) -> Unit raise TokenError
  async fn get_and_del(Self, String) -> String? raise TokenError
  async fn apply(Self, FamilyPatch) -> Unit raise TokenError
  async fn sweep(Self, Int64) -> Int raise TokenError
}
```

六条实现要求（前两条做错会**静默**改变库的对外行为，测试不一定红）：

1. **`get` 的惰性过期分两档**：载荷是 Active 会话、只过了签发时效 ⇒ 照旧返回载荷（否则 `SessionExpired`
   会退化成 `UnknownToken`，核心卖点没了）；载荷是墓碑且过了保留宽窗 ⇒ 当场回收。
2. **`get_and_del` 必须原子**：refresh 的重放防护整个压在它身上（Redis 用 `GETDEL`/Lua，SQL 用事务 + 行锁）。
3. **`apply` 是反向索引的唯一写入口**，且每个变体都要幂等（重复投递不重复加成员、不重复推 `version`）。
4. 补丁**不带时钟**：需要绝对时刻的地方一律传算好的 `deadline` / `expire_at`，这样多后端同判据同答案。
5. 后端失败一律 `raise @port.Store(msg)`，别另立错误类型——否则错误词汇表在端口边界断掉。
6. `sweep` 返回**真实**清掉的条数（用它断言"跑一万轮登录登出，键数不单调增长"）。

## 键位与线格式

```text
{realm}:T:{token}        会话记录        线格式 v=1：k=v|k=v，键与值都转义
{realm}:A:{login_id}     反查族          成员各自是编码后的记录，';' 连接，带 version
{realm}:R:{refresh}      refresh 绑定    login_id + device + 绑定的 access
{realm}:S:{login_id}     账号会话        跨该账号所有 token 共享的属性表
{realm}:D:{login_id}     封禁            until + reason
```

线格式由本包持有（`port/codec.mbt`），核心与适配器共用同一份编解码，所以不会出现"两实现各自发明字段名"。
**加字段安全**（解码按键取），**改字段名不安全**（旧数据解不开）——字段名一旦进过发布版本就是契约。

```moonbit
test "线格式扛得住分隔符、等号与中文" {
  let payload = @port.encode_record([("login", "张三|带竖线"), ("reason", "a=b&c;d")])
  match @port.decode_record(payload) {
    None => fail("往返失败")
    Some(fields) => {
      assert_eq(fields["login"], "张三|带竖线")
      assert_eq(fields["reason"], "a=b&c;d")
    }
  }
}
```

## 时钟槽

全库唯一时间源是 `@port.now_ms()`，读一个可注入槽；`None` 表示还原成真实时钟（`@env.now()`）。

```moonbit
test "注入即生效，还原即回真" {
  let cell = 1_000L
  @port.set_clock(Some(fn() { cell }))
  assert_eq(@port.now_ms(), 1000L)
  @port.set_clock(None)
  assert_true(@port.now_ms() > 1_700_000_000_000L)
}
```

## 文档与许可

契约细节、写法坑与后端清单见
[存储端口](https://github.com/mldong/moon-token/blob/master/docs/storage-port.md)，
错误原因表见[错误词汇表](https://github.com/mldong/moon-token/blob/master/docs/error-vocabulary.md)。

Apache-2.0。与 `mldong/moon-token` 同版本号、按拓扑序发布（本包先、核心后）。
