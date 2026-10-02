# 文件后端（store-file）

零 Redis、零 MySQL 的持久化：**内存为主 + 写穿透**。进程重启后会话还在，读路径不碰磁盘。

依赖方向是 `store-file → store`（`core` 不认识它，端口没变），所以它单独成模块
`mldong/moon-token-store-file`，`mldong/moon-token-store` 保持零第三方依赖、
`memory` 保持"纯内存基准"这一身份不变。

本页代码块由 `scripts/docs-check.sh` 逐块真编译真跑。

## 1. 装起来

```text
moon add mldong/moon-token-store mldong/moon-token mldong/moon-token-store-file
```

包别名（`moon.pkg`）：`file` 取自 `mldong/moon-token-store-file/file`，
它内部已经带好 `moonbitlang/async/fs`，你的包只需要再引 `async` 跑 `async fn main`。

## 2. 换一个构造点，其余代码不动

`FileStore` 实现的就是 [存储端口](storage-port.md) 那八个方法，所以 `TokenAuth` 一行都不用改。

```moonbit
async fn wire_up() -> String raise {
  // 目录必填：库不替用户决定会话数据落在哪。
  // 想要"不进 git"的位置，传 @fs.tmpdir 的结果即可（库还会在该目录里写一份 .gitignore）
  let dir = @fs.tmpdir(prefix="myapp-sessions.")
  let store = @file.FileStore::open("user", dir)
  store.set("user:S:demo", "v=1|login=demo", 0L)
  match store.get("user:S:demo") {
    None => "没读到"
    Some(text) => text
  }
}

async test "文件后端就是同一个端口" {
  assert_eq(wire_up(), "v=1|login=demo")
}
```

## 3. 三条实测出来的边界

数值全部来自探针（`moon test` 与本机实跑），不是估的：

- **写不写 fsync 差 45 倍**：每次写都 `sync=Data` 实测约 36 ms/次，`NoSync` 约 0.5 ms/次。
  所以默认 `NoSync`：进程被杀不丢（数据已经交给内核），整机断电才可能丢最后几页。
  要掉电安全就 `@file.FileStore::open("user", dir, durable=true)`。
- **每次写都是"写临时文件 + rename"**：探针实测这条路可用，直接写目标文件在进程中途被杀时
  会留下半截载荷。重开时 `.tmp` 残骸一律清掉，不参与判定。
- **键不直接当文件名**：探针在 Windows 上实测键里的 `:` 会把落盘名截断（写 `probe:tail`
  之后目录里只剩 `probe`，不报错、数据错位），`* ? < > |` 直接被系统拒。所以文件名只由
  "可读前缀 + 两条哈希 lane"组成，真键存在文件内容里；载入时两者必须对得上，对不上就跳过这个文件。

## 4. 过期什么时候落盘

载入这一步**一次时间都不读**：把盘上的键原样交回内存，判过期仍旧走内存版那条惰性路径
（`get` 读到过期即回收、`sweep` 批量收）。理由是别处踩过：给同一个"现在几点"引入第二个源，
就会出现在冷启动把活键当过期删掉的分叉。所以下面这个用例判的是两件事——
重开时两条键都还在，`sweep` 之后过期那条连内存条目带文件一起没了。

```moonbit
async fn sweep_takes_the_file_too() -> (Int, Int) raise {
  let dir = @fs.tmpdir(prefix="myapp-expiry.")
  let far = 4_000_000_000_000L
  let store = @file.FileStore::open("user", dir)
  store.set("user:T:live", "v=1|login=u1", far)
  store.set("user:T:dead", "v=1|login=u1", 1L)
  let reopened = @file.FileStore::open("user", dir)
  let before = @fs.readdir(reopened.dir_of()).length()
  reopened.sweep(2_000_000_000_000L) |> ignore
  let after = @fs.readdir(reopened.dir_of()).length()
  @fs.rmdir(dir, recursive=true)
  (before, after)
}

async test "载入不判时间，sweep 之后过期键的文件也没了" {
  let (before, after) = sweep_takes_the_file_too()
  // before：live + dead + .gitignore；after：dead 的文件被带走
  assert_eq(before, 3)
  assert_eq(after, 2)
}
```

## 5. 什么时候该用它，什么时候不该

适合：单机或会话副本不需要共享的部署、给 demo/内网工具减负、
以及"重启别把所有人踢下线"这一条就够了的场景。

不适合：多实例共享会话（文件后端只在**同机同目录**内一致，跨机器不行）、
需要即时统计在线数的大盘（那要走 Redis 的 `Z` 索引，见 [存储端口](storage-port.md) §6.1）、
以及把会话当审计凭证长期存的地方（这条与内存版一样：载荷里有 token 原文）。

## 6. 运维注意两件事

- 目录里全是"一个键一个文件"，量级是活跃会话数（不是用户数）。长跑请定期调 `sweep`，
  它同时负责把出窗条目的文件删掉，否则目录只涨不缩。
- 别把两个 realm 写到同一目录以外的地方共享，也别手工改文件名：
  文件名与内容里的键对不上时那条会被静默跳过（宁可少认一条会话，也不认错人）。
