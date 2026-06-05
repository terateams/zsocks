---
name: bench
description: 对 SOCKS5 代理（默认 zsocks）做多角度压测并生成详尽报告。当用户要求测试代理性能、跑 benchmark、压测 SOCKS5、用真实网站验证代理吞吐/延迟、对比国内外线路，或要求用无头浏览器（Lightpanda）模拟真实请求时使用。会先确认目标：缺代理地址或目标不清时，主动用「带选项的提问」（测试套餐 A/B/C/D/E）让用户选择而非擅自开跑；信息齐备后用仓库内 bench 工具对【国外/国内】两组站点【分别】跑【负载压测 + 无头浏览器 + 带宽峰值】测试，最后汇总成对比报告。
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
  分开测能区分跨境线路抖动 vs 域内表现。另有两个**大文件带宽峰值池**——
  `bench/sites-global-bw.txt`（国外，12–87MB × 8 个 CDN 主机）与
  `bench/sites-cn-bw.txt`（国内，24–70MB × 7 个镜像站）——分别用于测**国外/国内
  下载带宽峰值**，多源分散避免单站限流。
- **两类工具**：
  - `bench.zig`（`zig build bench`）— 零依赖 Zig 负载发生器，完整 SOCKS5 握手 +
    域名 ATYP（代理解析 DNS）+ 隧道内 TLS + HTTP GET。压并发、看吞吐/延迟分布。
  - `lpbench.sh` — 驱动 [Lightpanda](https://github.com/lightpanda-io/browser)
    无头浏览器，真实页面加载（完整 TLS + JS），贴近真人流量。
- **两个观察角度**（每组站点文件内已分区）：
  - *延迟角度*：小响应 / 204 / robots，反映建连与往返延迟。
  - *吞吐角度*：sized download / 镜像站，反映带宽与中继效率。

完整四象限都跑齐，才算“多角度覆盖”。

## 第一步：明确测试目标（信息不全时**主动提问 + 给选项**）

**原则：不要在目标不清时擅自跑一整套或随便挑参数。** 先判断用户给的信息是否
足以开跑，缺什么就用「带选项的提问」补齐，让用户在选项里选，而不是开放式发问。

### 1a. 唯一硬性前置：代理连接信息

没有代理地址就**无法测试**。若用户没给，必须先问（这是唯一不能用默认值兜底的项）：

> 请提供要测试的 SOCKS5 代理：
> 1. **代理地址** `host:port`（如 `1.2.3.4:1080`；bench.zig 需 IP 字面量，域名我来解析）
> 2. **是否需要认证**？(a) 否　(b) 是 → 请给用户名/密码
> 3. （可选）如果代理是你 RouterOS 容器里的 zsocks，可以告诉我 profile 名，我用
>    roswire 自动发现地址，你不必手填。

> 凭证含特殊字符（`@`/`:`）也没关系，照原样给我，我会处理编码（见“注意事项”）。

### 1b. 测试范围与强度：**给套餐让用户选**

代理信息齐了，但用户没说“想测什么/测多狠”时，**不要默认跑满**。给出预设套餐供选择：

| 选项 | 套餐 | 覆盖 | 大致耗时 | 适用 |
|------|------|------|---------|------|
| **A** | 快速冒烟 | 国外+国内压测各 `-n 30 -c 8`，不跑浏览器/带宽 | ~1–2 分钟 | 只想确认“通不通、快不快” |
| **B** | 标准多角度（默认） | 四象限（国外/国内 × 压测/浏览器），不含带宽峰值 | ~5–8 分钟 | 常规验收（**用户不选时用这个**） |
| **C** | 完整含带宽峰值 | 四象限 + 国外/国内两个带宽峰值池 | ~10–20 分钟 | 要看吞吐上限/出具完整报告 |
| **D** | 仅某一侧 | 只测国外 **或** 只测国内（用户指定一侧） | 视情况 | 只关心跨境 或 只关心域内 |
| **E** | 自定义 | 用户直接给 `-n`/`-c`/是否浏览器/是否带宽 | 视情况 | 有明确参数诉求 |

追加可选项（默认值在括号，用户没表态就用默认，并在回复里**说明所做假设**）：

- 是否跑无头浏览器？(默认：B/C 跑；A 不跑) — 资源紧张可只跑 bench.zig。
- TLS 是否跳过校验 `--insecure`？(默认：校验) — 自签证书代理才需要跳过。
- 出口预期在境内还是境外/未知？(默认：未知) — 影响对国内大文件慢/卡的解读。

> **何时直接开跑、不必问**：用户已把“代理信息 + 想测什么”说清楚（例如“压测一下这个
> 代理看带宽”“只测国外延迟”），就按其意图选最接近的套餐执行，无需再确认。
> **何时必须先问**：缺代理地址；或目标模糊到无法选套餐（如只说“测一下”又没给地址）。
> 只用一轮选项题问清，避免反复追问打断用户。

### 1c. 参数与默认值速查

| 信息 | 说明 | 默认 |
|------|------|------|
| 代理地址 | `host:port`。bench.zig 要求 **IP 字面量** | 无（必填，见 1a）|
| 认证 | 是否需要用户名/密码（RFC 1929） | 无认证 |
| 压测请求数 | bench.zig 每组 `-n` | 80（套餐 A=30）|
| 压测并发 | bench.zig `-c` | 16（套餐 A=8）|
| 浏览器请求数 | lpbench 每组 `-n` | 15 |
| 带宽峰值 | 是否跑大文件池 sites-*-bw.txt | 仅套餐 C |
| TLS 校验 | 是否跳过证书校验 `--insecure`（自签证书时） | 校验 |
| 是否跑无头浏览器 | 资源紧张/无需要时可只跑 bench.zig | 跑（套餐 A 不跑）|

> 若代理是远端/跨境出口，单个大文件会拖慢整组，请把每组 `-n` 控制在
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

## 第四步：按所选套餐执行测试（国外/国内 × 压测/浏览器 + 带宽）

> **跑哪些步取决于第一步选定的套餐**：A=只跑 1)2)（且 `-n 30 -c 8`）；
> B=跑 1)~4)；C=跑 1)~6) 全套；D=只跑对应一侧的 1)3)（或 2)4)，按需加 5/6）；
> E=按用户给的参数。下面给出全部步骤，按套餐取子集即可。

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

**5) 国外 — 下载带宽峰值**（大文件多源，找跨境吞吐上限）
```bash
zig-out/bin/zsocks-bench --proxy "$P" $AUTH --list bench/sites-global-bw.txt -n 40 -c 16
```
**6) 国内 — 下载带宽峰值**（大文件多源，找域内吞吐上限）
```bash
zig-out/bin/zsocks-bench --proxy "$P" $AUTH --list bench/sites-cn-bw.txt -n 40 -c 16
```
> 每个目标 12–87MB，bench.zig 会下完整 body。判断瓶颈：若提高并发吞吐不再上升、
> 同时代理 CPU 仍低（见下方采样），则峰值受**出口带宽/网络路径**所限而非代理。
> 对比国外 vs 国内两个带宽峰值，可看出代理出口对哪侧线路更友好（如出口在境外，
> 国内大文件常出现吞吐骤降甚至卡住）。

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

   外加**带宽峰值对比**（大文件池，bench.zig）：

   | 带宽峰值 | 国外 (sites-global-bw) | 国内 (sites-cn-bw) |
   |---------|------------------------|--------------------|
   | 成功率 | | |
   | 峰值吞吐 Mbps | | |
   | 数据量 / 用时 | | |
   | 是否随并发饱和 | | |

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
- **认证凭证含特殊字符**（如 `@`、`:`）：
  - bench.zig 用独立的 `--user/--pass`，不受影响。
  - curl 用 `-x socks5h://host:port --proxy-user "user:pass"`（按首个 `:` 拆分），
    不要用内联 `socks5h://user:pass@host:port`。
  - lpbench.sh 会拼成 `socks5h://user:pass@host:port`，凭证里的 `@`/`:` 必须先做
    URL 编码（`@`→`%40`、`:`→`%3A`），例如 `--user 'her%40alliedai.cn' --pass 'Her%40hello189'`。
- **bench.zig 无单请求超时**：某个被限流/黑洞的目标会一直挂住一个 worker，使整组
  p99/max 极高甚至卡死（远端跨境代理访问国内大文件时常见）。这是工具已知限制，
  报告里要把「单目标长尾/卡死」与「代理故障」区分开。
- 在 musl/Alpine 上 Lightpanda nightly 为 glibc 链接可能无法运行，此时跳过浏览器
  象限并注明。
- 详尽用法见仓库 `bench/README.md`。
