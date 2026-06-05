---
name: bench
description: 对 SOCKS5 代理（默认 zsocks）做多角度压测并生成详尽报告。当用户要求测试代理性能、跑 benchmark、压测 SOCKS5、用真实网站验证代理吞吐/延迟、对比国内外线路，或要求用无头浏览器（Lightpanda）模拟真实请求时使用。会先收集代理连接信息，再用仓库内 bench 工具对【国外/国内】两组站点【分别】跑【负载压测 + 无头浏览器】两类测试，最后汇总成对比报告。
---

# Bench

对 SOCKS5 代理做**多角度**压测并产出**详尽对比报告**。核心方法：把站点池拆成
**国外（global）** 与 **国内（cn）** 两组，分别测试，且每组都跑两类工具，避免单一
视角失真，也便于定位是线路问题还是代理问题。

## 测试矩阵（四象限 + 两个观察角度）

|        | 负载压测 `bench.zig` | 无头浏览器 `lpbench.sh` |
|--------|----------------------|--------------------------|
| 国外 global | 原始吞吐 + 并发延迟 | 真实页面加载（TLS+JS） |
| 国内 cn     | 原始吞吐 + 并发延迟 | 真实页面加载（TLS+JS） |

- **两组站点**：`bench/sites-global.txt`（国外）、`bench/sites-cn.txt`（国内）。
  分开测能区分跨境线路抖动 vs 域内表现。
- **两类工具**：
  - `bench.zig`（`zig build bench`）— 零依赖 Zig 负载发生器，完整 SOCKS5 握手 +
    域名 ATYP（代理解析 DNS）+ 隧道内 TLS + HTTP GET。压并发、看吞吐/延迟分布。
  - `lpbench.sh` — 驱动 [Lightpanda](https://github.com/lightpanda-io/browser)
    无头浏览器，真实页面加载（完整 TLS + JS），贴近真人流量。
- **两个观察角度**（每组站点文件内已分区）：
  - *延迟角度*：小响应 / 204 / robots，反映建连与往返延迟。
  - *吞吐角度*：sized download / 镜像站，反映带宽与中继效率。

完整四象限都跑齐，才算“多角度覆盖”。

## 第一步：向用户收集代理信息

跑测试前确认以下信息（缺失项用括号默认值并说明假设）：

| 信息 | 说明 | 默认 |
|------|------|------|
| 代理地址 | `host:port`。bench.zig 要求 **IP 字面量** | `127.0.0.1:1080` |
| 认证 | 是否需要用户名/密码（RFC 1929） | 无认证 |
| 压测请求数 | bench.zig 每组 `-n` | 80 |
| 压测并发 | bench.zig `-c` | 16 |
| 浏览器请求数 | lpbench 每组 `-n` | 15 |
| TLS 校验 | 是否跳过证书校验 `--insecure`（自签证书时） | 校验 |
| 是否跑无头浏览器 | 资源紧张/无需要时可只跑 bench.zig | 跑 |

> 若代理是远端/跨境出口，单个 10MB 下载会拖慢整组，请把每组 `-n` 控制在
> 数十量级，或在报告中标注线路带宽瓶颈。

### 远端代理地址发现（可选，roswire）

如果代理跑在 RouterOS 容器里，可用 `roswire` 自动发现地址：

```bash
roswire --json config profiles                                  # 找 profile
roswire --json --profile <p> raw /container/print               # 看 zsocks 容器 cmd（端口/认证）
roswire --json --profile <p> ip firewall nat print              # 找 dst-nat 暴露端口
roswire --json --profile <p> ip address print                   # 找可达的 LAN/veth 地址
```

用户给出的代理认证以容器 `cmd`（`-u/-P`）为准；对外测试地址通常是
“路由器 LAN IP : dst-nat 端口”。

## 第二步：确认代理可达

```bash
nc -z -w3 <host> <port> && echo "reachable" || echo "NOT reachable"
```

不可达时提示用户检查/启动代理（本地示例）：

```bash
zig build -Doptimize=ReleaseFast
zig-out/bin/zsocks -l 127.0.0.1 -p 1080 --max-conns 512
```

## 第三步：构建工具

负载发生器用 ReleaseFast 以免成为瓶颈；无头浏览器首次需下载二进制：

```bash
zig build bench -Doptimize=ReleaseFast -- --version     # 产出 zig-out/bin/zsocks-bench
bench/lpbench.sh --install --proxy <host:port> -n 1     # 首次下载 Lightpanda nightly（~63MB）
```

## 第四步：四象限测试（国外/国内 × 压测/浏览器）

设变量便于复用（按实际填写）：

```bash
P="<host:port>"; AUTH="--user <u> --pass <p>"   # 无认证则 AUTH=""
LP_AUTH="--user <u> --pass <p>"                  # lpbench 同上；无认证则置空
```

**1) 国外 — 负载压测**
```bash
zig-out/bin/zsocks-bench --proxy "$P" $AUTH --list bench/sites-global.txt -n 80 -c 16
```
**2) 国内 — 负载压测**
```bash
zig-out/bin/zsocks-bench --proxy "$P" $AUTH --list bench/sites-cn.txt -n 80 -c 16
```
**3) 国外 — 无头浏览器**
```bash
bench/lpbench.sh --proxy "$P" $LP_AUTH --list bench/sites-global.txt -n 15
```
**4) 国内 — 无头浏览器**
```bash
bench/lpbench.sh --proxy "$P" $LP_AUTH --list bench/sites-cn.txt -n 15
```

参数速查见 `bench/README.md`。常见可调项：`-n` 总数、`-c` 并发（仅 bench.zig）、
`--insecure` 跳过 TLS 校验、`--seed` 复现站点选择。

### 同时采样代理侧资源（强烈建议）

压测进行时，采样代理进程/容器的 CPU 与常驻内存，验证“资源有界、不抢占宿主”。

本地进程：
```bash
ps -o rss= -p <zsocks-pid>     # 多次采样，应保持平稳
```

RouterOS 容器（roswire）：
```bash
roswire --json --profile <p> raw /container/print     # 取 cpu-usage / memory-current
roswire --json --profile <p> raw /system/resource/print  # 路由器整机 cpu-load / free-memory
```

## 第五步：输出详尽报告

把四象限结果整理成**结构化对比报告**，不要直接粘贴整段原始日志。至少包含：

1. **测试环境**
   - 代理地址、发现方式（如 roswire 容器+dst-nat）、认证开关、出口位置（境内/跨境）。
   - 测试机位置与到代理的网络路径、时间戳、工具版本、各项 `-n`/`-c`。
2. **结果矩阵**（四象限对比表）

   | 维度 | 国外 压测 | 国内 压测 | 国外 浏览器 | 国内 浏览器 |
   |------|----------|----------|------------|------------|
   | 成功率 | | | | |
   | req/s 或 页/s | | | | |
   | 吞吐 Mbps | | | n/a | n/a |
   | total p50/p95/p99 (ms) | | | | |
   | 错误分类 | | | | |

3. **分角度解读**
   - *延迟 vs 吞吐*：小响应站点的 ttfb 体现建连开销；sized download 体现带宽中继。
   - *国外 vs 国内*：对比 RTT 与成功率差异，判断是跨境线路问题还是代理问题。
   - *压测 vs 浏览器*：原始中继 OK 但浏览器失败 → 可能 TLS/SNI/DNS 行为差异；
     反之浏览器 OK 但压测高错误 → 多为高并发下上游限流/连接复位。
4. **每站点表现**：列出失败或显著拖慢的站点，明确区分「单站点限流/网络」与
   「代理故障」（失败集中在单站点通常不是代理问题）。
5. **代理资源**：CPU 峰值、常驻内存峰值，是否保持有界（zsocks 典型 <20MB 恒定）。
6. **结论与建议**：是否达标、瓶颈定位（出口带宽 / 跨境 RTT / 上游限流 / 代理）、
   下一步加压或排查方向。

报告骨架示例：

```
## SOCKS5 多角度压测报告
### 环境
- 代理: 10.189.189.1:11080（RouterOS 容器 zsocks-test，dst-nat→172.30.67.2:1080），认证开
- 工具: zsocks-bench(ReleaseFast) / Lightpanda nightly；压测 n=80 c=16，浏览器 n=15
### 结果矩阵
| 维度 | 国外压测 | 国内压测 | 国外浏览器 | 国内浏览器 |
| 成功率 | 100% | 100% | 100% | 100% |
| 吞吐 | 22 Mbps | 60 Mbps | n/a | n/a |
| total p95(ms) | 8600 | 1200 | 5100 | 1300 |
| 错误 | 无 | 无 | 无 | 无 |
### 解读
- 国内 RTT/吞吐明显优于国外 → 出口在境内，跨境线路是主要延迟来源，非代理瓶颈。
- 压测与浏览器结论一致，TLS/DNS 行为正常。
### 资源
- 容器 CPU 峰值 ~0.3%，内存 17MB 恒定（有界）。
### 结论
- 代理稳定达标；跨境吞吐受线路限制。建议境内场景可放心共享，跨境重负载需评估带宽。
```

## 注意事项

- bench.zig 的 `--proxy` 必须用 IP 字面量；目标以域名 ATYP 传给代理，由代理解析
  DNS（正是要压的路径）。lpbench 经 libcurl 用 `socks5h://`（远端 DNS），与之一致。
- `speed.cloudflare.com/__down` 等非 HTML 接口只适合 bench.zig 量吞吐；无头浏览器
  对其只会抓到极少字节，**不要**用它评判浏览器吞吐。
- 跨境/远端代理的低吞吐多为出口带宽或 RTT 所致，需与代理故障区分清楚并在报告说明。
- 在 musl/Alpine 上 Lightpanda nightly 为 glibc 链接可能无法运行，此时跳过浏览器
  象限并注明。
- 详尽用法见仓库 `bench/README.md`。
