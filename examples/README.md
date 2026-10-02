# moon-token examples

不发布的示例模块。`cmd/main` 是一个自包含的 HTTP 门面（手写十行路由，不引任何 web 框架），
把库的每个用例露成一个端点：`/login`、`/rotate`、`/kick`、`/logout`、`/whoami`、
`/api/**`（受守卫保护）、`/api/public/**`（守卫豁免腿）。

```bash
moon run --target wasm examples/cmd/main      # 起在 http://127.0.0.1:18890
bash examples/curl.sh                         # 13 步剧本，逐步断言精确原因
```

用法文档在仓库的 `docs/`，从[快速开始](../docs/quick-start.md)读起。
