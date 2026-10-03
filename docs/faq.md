# 常见问题

按"接进来第一天就会撞的"排序。能跑的答复都带代码，由 `scripts/docs-check.sh` 逐块真编译真跑。

## Q1 进程重启，会话全没了？

对。v1 只交付内存档，这是设计而不是缺陷——它换来"零外部依赖、本地 `moon add` 就能跑"。
要持久化就实现 `TokenStore` 那八个方法（Redis / SQL 都行），库这边一行不改：
见 [存储端口](storage-port.md) §6 的换后端清单。

## Q2 多实例部署怎么办？

`TokenAuth` 实例本身**无状态**，状态全在 `store` 里。所以多实例只要共享同一个后端即可：

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

pub impl @port.PermissionProvider for P with fn is_super_admin(
  _self,
  _login_id,
  _device,
) {
  false
}

pub extend P with @port.PermissionProvider::{
  get_permissions,
  get_roles,
  is_super_admin,
}

async fn shared_store() -> Bool raise {
  // 同一个 store、同一个 realm，两个实例看到同一份会话
  let store = @mem.MemoryStore::new("user")
  let p : P = { permissions: [], roles: [] }
  let one = @app.TokenAuth::new("user", @app.TokenConfig::default(), store, p, @style.opaque_style())
  let two = @app.TokenAuth::new("user", @app.TokenConfig::default(), store, p, @style.opaque_style())
  let t = one.login("u1", device="pc").token
  let seen_elsewhere = two.check_login(t)
  one.kickout("u1") |> ignore
  // 实例 A 踢的，实例 B 立刻认得：因为库里只有一份状态
  seen_elsewhere == "u1" && !two.is_login(t)
}

async test "两个实例共享一个 store：状态互通" {
  assert_true(shared_store())
}
```

注意 `realm` 必须一致——realm 是键前缀，不同 realm 的实例就算共用 store 也互相看不见。

## Q3 为什么 token 是 40 字符小写 base32？

- **熵够**：40 × 5 bit = 200 bit，暴力枚举不成立。
- **免转义**：只用 `a-z0-9`，放进 URL、header、日志都不用编码。
- **不分大小写**：避免"网关把 header 规范化了导致对不上"这类极难排查的问题。

长度可配：`@style.opaque_style(len=64)`（内部按熵字节数换算，不是截断）。
**别把长度调到 20 以下**——那等于把 200 bit 砍成 100 bit 以下。

```moonbit
test "长度可配，形状校验跟着走" {
  let long = @style.opaque_style(len=64)
  let t = (long.generate)()
  assert_eq(t.length(), 64)
  assert_true((long.verify_shape)(t))
  let plain = @style.opaque_style()
  // 默认档 40 字符喂给"应为 64 字符"的形状校验，必须不认
  assert_false((long.verify_shape)((plain.generate)()))
}
```

## Q4 跟 JWT 比呢？

不透明 token 换来了**即时吊销**：踢人、封禁、顶号在库里改一条记录，下一次请求就生效。
JWT 的"服务端不存状态"是拿吊销能力换的——要么等它自然过期，要么自己维护黑名单，
而一旦维护黑名单，你其实又回到了"有状态存储"，只是少了即时性。

本库 v1 不做 JWT（不做签名/验签、不解析 claims）。要接的话，`TokenStyleFns` 是可替换的，
但**换掉之后"精确吊销"这条卖点就没了**，这是取舍不是白拿。

## Q5 能只存 token 的哈希吗？

诚实答复：**当前契约下不能**。`T:` 键就是用 token 本身拼的，读路径是"按 token 取键"。
要在存储层落哈希，需要改键位约定（`KeySpace` 属于共享内核，v1 不开放这个钩子）。

现实里的缓解做法是后端侧的：给存储加访问控制、开审计、别把 token 打进日志。
如果你的合规要求确实到"存储必须不可逆"，请在 issue 里说明场景——这条会决定它进不进 v2 的优先级。

## Q6 为什么没有注解式鉴权？

MoonBit 有 `#attr(...)` 这个语法，但**自定义注解编译器不认，语言也不支持运行时反射**，
注解只能被"自己写的编译期工具"消费。要注解式就得配三件套：codegen 工具 + 构建钩子
（`rule` / `dev_build`）+ 生成物提交进仓库。而注解承载的本来就是 `{path → perms, mode}` 这张表，
表定下来之后，"就地写"和"集中写"只是同一份数据的两种摆放。

所以本库直接把表做成值（`RoutePolicy`），运行时等价物是 `RouteGuard` 的闭包链 + `check_route`，
见 [路由权限策略](route-policy.md) §6。显式写法的副产品是：权限要求能在一张表里看全，不藏在方法签名上。

## Q7 `has_permission` 为什么不返回 `false` 反而抛错？

因为它内部第一步是鉴权。**身份不成立**（没登录/被踢/过期）与**权限不够**是两件事，
混成 `false` 之后前端就没法区分"该跳登录页"还是"该提示无权限"。

要 bool 就用 `has_permission`（它只在权限这一档给 bool），要"要么过要么报错"用 `check_permission`。
详见 [权限与角色](permissions.md) §5 与 [错误词汇表](error-vocabulary.md)。

顺带一条同源的坑：**业务里改了某人的角色/权限，他的老会话不会自己看到新数**——
权限/角色/超管位是跟着 token 缓存的授权快照，改完要调 `invalidate_grants(login_id)`。
见 [权限与角色](permissions.md) §2。

## Q8 同一个人既属于 `user` 体系又属于 `admin` 体系？

realm 是**实例级**隔离：两边各一枚会话、各一份时效、互不影响。
"同一个人"的对应关系属于业务（一个 `login_id` 映射表），库不掺和——掺和的结果是
两边权限集互相污染，那比多写一次登录麻烦得多。

```moonbit
async fn two_realms_one_person() -> Bool raise {
  let p : P = { permissions: ["user:info"], roles: [] }
  let user = @app.TokenAuth::new("user", @app.TokenConfig::default(), @mem.MemoryStore::new("user"), p, @style.opaque_style())
  let admin = @app.TokenAuth::new("admin", @app.TokenConfig::default(), @mem.MemoryStore::new("admin"), p, @style.opaque_style())
  let t = user.login("mldong", device="pc").token
  user.is_login(t) && !admin.is_login(t)
}

async test "两个 realm 各自独立：跨体系不认账" {
  assert_true(two_realms_one_person())
}
```

## Q9 时钟为什么是全局槽，不是每个方法传参？

为了**契约零依赖**：`TokenStore` 的方法签名里没有 clock 参数，
补丁也不带时钟（只带算好的 `deadline` / `expire_at`）。这样多后端拿到同一批补丁必然同判据同答案。
代价就是它全局：并发跑共享时钟的用例要串行化。

## Q10 我改了一个默认配置，旧会话行为变了？

不会。时效是**签发时**算成绝对时刻写进会话的，改配置只影响新签发的会话。
`concurrent`、`renewal` 同理——不追溯。
唯一"改了立刻全量生效"的是 `token_name` / `token_prefix`：它们影响的是**读头**，
配错会让所有旧客户端立刻报 `AbsentToken`（注意不是 `UnknownToken`，这个区分能帮你三分钟定位）。
详见 [配置与默认值](configuration.md) §4。

## Q11 升级会不会读不懂旧数据？

线格式带版本号（`v=1`），解码按键取：

- **加字段安全**——旧数据解出来该字段走默认值。
- **改字段名不安全**——旧数据直接解不开。所以字段名一旦进过发布版本就是契约。

`FamilyPatch` 的变体、`NotLoginReason` 的码值、事件码（1–7，10+ 预留）同理：
只加不改不删。这条在 [存储端口](storage-port.md) §5 与 [领域事件](events.md) §1 各自钉了一遍。

## Q12 为什么 `kickout` 之后 token 还能读到"被踢"，过一会儿变成"查无此枚"？

墓碑保留窗（`kick_grace`，默认 5 分钟）。窗内保留状态是为了**给出原因**；
窗外回收是为了**不留垃圾**。这不是不一致，是两件事各自的时间窗。
前端建议：`KickedOut` 弹"您已在别处登录"，`UnknownToken` 静默跳登录页。

## Q13 该库适合什么、不适合什么

适合：需要即时吊销的会话、多端并发策略、按账号批量操作（踢/顶/封）、双层时效。
不适合：无状态验签场景（那是 JWT 的活）、跨服务共享密钥的 SSO（v1 没有这个概念）、
需要把会话塞进 CDN 边缘的场景。

## Q14 还没做的那两个后端，什么时候做

**端口上预留的口子，不在当前排期里。** `store-redis`（`Z` 索引 + Lua 原子 `get_and_del`）与
事务型 SQL 后端（MySQL 8 那条 `get_and_del` 得走事务）要等第三方驱动库稳定之后再实现，
判据很具体：能否在 wasm 与 native 两个目标上都跑通并保持版本线同步。第三方成熟之前先自己搓一层
客户端，等于把别人正在收敛的接口焊进我们的依赖面，不值。

口子本身已经留好：`TokenStore` 那八个方法与意图补丁不随后端变，`data-model.md` §6 已经把
Redis 与 SQL 两套物理映射（含 "`T:` 的 TTL 要设到 `expire_at + kick_grace`" 这类会静默掉原因的坑）钉死，
届时实现只需照表填，业务代码与适配接口一行都不用改。

顺带更正这条老答案里的一处过期信息：web 防腐层已经交付，就是 `mldong/moon-token-moonback`
（逐路由守卫、主体进请求上下文、失败映射状态码或换成框架自己的应答信封）。
