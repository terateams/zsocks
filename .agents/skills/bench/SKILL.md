---
name: bench
description: 对 SOCKS5 代理（默认 zsocks）做压测并生成测试报告。当用户要求测试代理性能、跑 benchmark、压测 SOCKS5、用真实网站验证代理吞吐/延迟，或要求用 Lightpanda 模拟真实浏览器请求时使用。会先向用户收集代理连接信息，再调用仓库内的 bench 工具（zig build bench / bench/lpbench.sh）执行测试并汇总成报告。
---

# Bench

使用本仓库 `bench/` 下的两个工具对 SOCKS5 代理做压测并产出报告。两个工具都从
随机站点池中按请求挑选目标，避免单站点限流。

- **bench.zig**（`zig build bench`）：零依赖 Zig 负载发生器，走完整 SOCKS5
  握手 + 域名 ATYP（由代理解析 DNS）+ 隧道内 TLS + HTTP/1.1 GET，输出
  req/s、吞吐（MB / Mbps）、ttfb/total 的 p50/p95/p99、按站点成功数、错误分类。
  **这是默认主测工具。**
- **lpbench.sh**：驱动 [Lightpanda](https://github.com/lightpanda-io/browser)
  无头浏览器，做真实页面加载（完整 TLS + JS），更贴近真人流量。仅在用户明确
  需要“真实浏览器/真实请求”模拟时使用（需下载 ~63MB nightly 二进制）。

## 第一步：向用户收集代理信息

在跑测试前，必须先确认以下信息（缺失项用括号内默认值并向用户说明假设）：

| 信息 | 说明 | 默认 |
|------|------|------|
| 代理地址 | `host:port`。bench.zig 要求是 **IP 字面量**（非域名） | `127.0.0.1:1080` |
| 认证 | 是否需要用户名/密码（RFC 1929） | 无认证 |
| 请求数 | 总请求数 `-n` | bench.zig 100 / lpbench 20 |
| 并发 | 工作线程数 `-c`（仅 bench.zig） | 10 |
| TLS 校验 | 是否跳过证书校验 `--insecure`（自签证书时） | 校验 |
| 站点池 | 自定义 URL 列表文件 `--list` | `bench/sites.txt` 内置池 |
| 工具 | 仅 bench.zig，还是也跑 lpbench 真实浏览器 | 仅 bench.zig |

如果用户只给了“测一下代理 127.0.0.1:1080”，就用默认值开跑，并在报告里标注所用参数。

## 第二步：确认代理可达

```bash
# 确认目标端口有监听（macOS/Linux 通用）
nc -z -w3 <host> <port> && echo "reachable" || echo "NOT reachable"
```

若不可达，先提示用户启动/检查代理，例如本地 zsocks：

```bash
zig build -Doptimize=ReleaseFast
zig-out/bin/zsocks -l 127.0.0.1 -p 1080 --max-conns 512
```

## 第三步：运行 bench.zig（主测）

```bash
# 通过 build 步骤运行（-- 之后是工具参数）
zig build bench -- --proxy <host:port> -n <N> -c <C> [--user <u> --pass <p>] [--insecure] [--list bench/sites.txt]

# 或直接运行已安装的二进制
zig-out/bin/zsocks-bench --proxy <host:port> -n <N> -c <C> [...]
```

参数速查：

```
--proxy <ip:port>   SOCKS5 代理（IP 字面量，默认 127.0.0.1:1080）
--user / --pass     SOCKS5 认证
--list <file>       URL 池文件（默认内置 21 站点池）
-n, --requests <N>  总请求数（默认 100）
-c, --concurrency   并发线程数（默认 10）
--seed <n>          固定随机种子，便于复现站点选择
--insecure          跳过 TLS 证书/主机名校验
```

建议梯度：先 `-n 50 -c 8` 冒烟，再按需 `-n 500 -c 32` 加压。压测时可同时采样
代理进程常驻内存，验证“内存有界”：

```bash
ps -o rss= -p <zsocks-pid>   # 不随传输字节增长
```

## 第四步（可选）：运行 lpbench.sh（真实浏览器）

仅当用户需要真实浏览器/JS 模拟时：

```bash
# 首次运行自动下载对应平台 nightly 到 bench/lightpanda（已被 .gitignore 忽略）
bench/lpbench.sh --install --proxy <host:port> -n <N>

# 已有二进制后
bench/lpbench.sh --proxy <host:port> -n <N> [--user <u> --pass <p>] [--insecure] [--dump html|markdown]
```

> lpbench 经 libcurl 用 `socks5h://`（远端 DNS，与 zsocks 域名 ATYP 行为一致）。
> 在 musl/Alpine 上 nightly 为 glibc 链接，可能无法运行——此时跳过本步并说明。

## 第五步：生成报告

把工具输出整理为简洁报告，**不要**直接粘贴整段原始日志。报告应包含：

1. **测试配置**：代理地址、认证开关、工具、`-n`/`-c`、TLS 校验、站点池、时间戳。
2. **结果汇总**：
   - bench.zig：成功率、req/s、总量（MB）、吞吐（Mbps）、ttfb 与 total 的
     p50/p95/p99/max、错误分类（connect / auth / tls / http / io）。
   - lpbench：成功率、页面加载延迟 p50/p95/p99/max、抓取内容量。
3. **每站点表现**：是否有特定站点失败或显著拖慢（区分代理问题 vs 单站点限流/网络）。
4. **内存**：若采样了 RSS，给出峰值并说明是否保持有界。
5. **结论与建议**：是否达标、瓶颈所在、下一步加压或排查建议。

报告示例骨架：

```
## SOCKS5 压测报告
- 配置: proxy=127.0.0.1:1080, auth=无, 工具=bench.zig, n=500 c=32, TLS校验=开
- 结果: 成功 500/500 (100%), 142 req/s, 856 MB, 612 Mbps
- 延迟(ms): ttfb p50/p95/p99 = 41/118/203; total p50/p95/p99 = 95/340/612
- 错误: 无
- 内存: 代理 RSS 峰值 10.1 MB（有界）
- 结论: 吞吐与延迟正常，无错误；建议 c=64 进一步探顶。
```

## 注意事项

- bench.zig 的 `--proxy` 必须用 IP 字面量；目标站点以域名 ATYP 传给代理，
  由代理侧解析 DNS（正是要压的路径）。
- 默认站点池含国内外站点和不同体积的下载，结果含真实网络抖动；要看“纯代理
  开销”请缩小到稳定站点或提高并发取相对值。
- 失败大量集中在单一站点通常是该站点限流/网络问题，不一定是代理故障，需在
  报告中区分。
- 详尽用法见仓库 `bench/README.md`。
