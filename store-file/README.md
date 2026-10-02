# moon-token-store-file

`mldong/moon-token` 的**文件后端**：零 Redis、零 MySQL 的持久化。
内存为主 + 写穿透，进程重启后会话还在，读路径不碰磁盘。

实现的是 `mldong/moon-token-store` 里那个 `TokenStore` 端口，所以 `TokenAuth` 一行都不用改。

```bash
moon add mldong/moon-token-store-file
```

## 用法

```moonbit
async fn uses_file_store() -> String raise {
  // 目录必填：库不替用户决定会话数据落在哪。
  // 想要一个"不进 git"的默认位置，传 @fs.tmpdir 的结果即可（库还会在该目录里写一份 .gitignore）
  let dir = @fs.tmpdir(prefix="myapp-sessions.")
  let store = @file.FileStore::open("user", dir)
  store.set("user:S:demo", "v=1|login=demo", 0L)
  let reopened = @file.FileStore::open("user", dir)
  match reopened.get("user:S:demo") {
    None => "没读到"
    Some(text) => text
  }
}

async test "文件后端就是同一个端口" {
  assert_eq(uses_file_store(), "v=1|login=demo")
}
```

## 三条实测出来的边界

数值来自本机探针（wasm/moonrun 与 Linux native 两档），不是估的：

- **默认不 fsync**：每次写都 fsync 实测约 36 ms/次，`NoSync` 约 0.5 ms/次，差 45 倍。
  进程被杀不丢（写入已交内核），整机断电才可能丢最后几页；要掉电安全传 `durable=true`。
- **写临时文件再 rename**：直接写目标文件在进程中途被杀时会留半截载荷；重开时 `.tmp` 残骸一律清掉。
- **键不直接当文件名**：Windows 上键里的 `:` 会把落盘名截断（实测写 `probe:tail` 之后目录里只剩 `probe`，
  不报错、数据错位），`* ? < > |` 被系统拒。所以文件名只由"可读前缀 + 两条哈希 lane"组成，
  真键存在文件内容里，载入时两者必须对得上，对不上就跳过那条。

## 文档

分层设计、TTL 公式与后端验收清单：
[数据模型](https://github.com/mldong/moon-token/blob/master/docs/data-model.md)、
[存储端口](https://github.com/mldong/moon-token/blob/master/docs/storage-port.md)、
[文件后端口径](https://github.com/mldong/moon-token/blob/master/docs/file-store.md)。

## 许可与家族

Apache-2.0。同家族四模块：`mldong/moon-token`（核心）、`mldong/moon-token-store`（契约与内存适配器）、
本模块（文件后端）、`mldong/moon-token-moonback`（moonback 适配层）。版本号一致，
按拓扑序发布（store 先，其余三个后）。
