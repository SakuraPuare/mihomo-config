# 通用 mihomo 配置设计

一份源、两份成品:网关 eBPF tproxy(`gateway.yaml`)+ 全平台客户端 TUN(`client.yaml`)。
目标:全平台通用、日常零维护、规则极简、多机场按优先级 fallback、防 EOF、DNS 不泄漏且冷启动自愈。

## 为什么用构建脚本(方案 C via A)

mihomo 没有跨文件 `include`/merge 顶层配置的能力,YAML anchor 也只在单文件内有效。
所以"模块化拆分 + 生成多份成品"只能靠一个 build 脚本把 `src/` 片段拼装。
两份成品**只有入口段不同**(端口/TUN/面板),providers/groups/rules/dns 完全同源。

## 出口拓扑(两级)

```
🚀 节点选择 (select, 默认=⚡自动)      ← 普通出海规则都指它;手动点这里,全局生效
├─ ⚡ 自动
├─ <每家>-均衡 / DIRECT
└─ use: 各 provider(展开全部具体节点,可精确手选)

⚡ 自动 (fallback, 按 providers.conf 顺序)
└─ P1-均衡 → P2-均衡 → P3-均衡 → P4-均衡

🤖 AI (fallback, 同优先级, 每家只筛 US/SG)
└─ P1-USSG → P2-USSG → P3-USSG → P4-USSG

每个槽位两个 load-balance 组(consistent-hashing + health-check 60s + max-failed-times 3):
  <槽位>-均衡 : use:[该槽位]  全节点
  <槽位>-USSG : use:[该槽位]  filter=美国|新加坡|us|sg|singapore
```

- **同一家内部**:load-balance 分摊流量,坏节点被 health-check 剔除。
- **跨家**:fallback 按优先级,整家探活失败自动切下一家。
- **订阅绝不混合**:每个组 `use:` 只挂单一 provider,`additional-prefix` 隔离节点名。
- **订阅拉取强制直连**:每个 provider 带 `proxy: DIRECT`。机场面板域名对代理出口 IP 常返 403
  (风控),必须直连拉取;国内镜像走直连也正常,故所有 provider 统一 `proxy: DIRECT`,零成本防 403。

## 手动高于一切(路线 1)

普通出海流量全经 `🚀 节点选择`(select),手动点选即全局严格生效。
AI 走独立 `🤖 AI`,默认锁 US/SG 防封号,**手动误选香港不连累 AI**。
mihomo 组只有单一当前值、无"全局强制覆盖"开关,故 AI 独立保护与 AI 跟随手动二者只能取其一,
本设计取"AI 焊死 US/SG"。需要时可去 🤖 AI 组手动切一次。

## 极简规则(中间档,共 8 条)

私有/基建直连 → AI 全家走 🤖 AI → 国内直连 → 兜底走 🚀 节点选择。
AI 域名用 meta-rules-dat 官方 `category-ai-!cn` 分类,自动更新零维护。
砍掉原 YouTube/Netflix/Spotify/哔哩/巴哈/Telegram/Github 全部分平台组。

## DNS(fake-ip + 全 DoH + 三层引导)

- **防泄漏**:fake-ip 对境外域名只回假 IP,真实解析在代理对端(remote),运营商看不到境外查询。
- **冷启动自愈**:`proxy-server-nameserver` 用纯 IP DoH(`https://223.5.5.5/dns-query`)直连解析
  "代理节点自己的域名",不依赖任何代理就绪 → 打破"连代理要先解析节点域名、解析又要走代理"死锁。
- **速度**:fake-ip 秒回;直连域名用 IP 端点 DoH,省一次解析 DNS 服务器域名的往返。
- **IPv6 全关**(`ipv6: false`):境外 v6 无代理出口易超时,关掉让境外一律回落 v4 进代理。
  全屋 v6 双栈由 Landscape 转发层单独管,与此 DNS 无关。
- **直连拿真 IP**:`fake-ip-filter` + `blacklist` 模式,把 `rule-set:cn_domain`/`private`/基建域名
  整体排除出 fake-ip → 走真实解析拿真 IP。与规则的 cn_domain 复用同一份数据,零维护。

## 安全隔离

- 真实订阅 URL + 面板 secret 放 `secrets.local.env`(gitignore),repo 只有占位符。
- `dist/`(注入后成品)也 gitignore。
- `build.sh` 缺 secrets 直接报错,绝不用占位符产出"看似可用"的配置。

## 已知边界

传输中被机场单方 RST 的**单条连接**无法续接(破坏协议),是所有代理的天花板。
两级 fallback + health-check 只保证**新建连接**永远落在健康家/节点,日常近乎无感,但非"零 EOF"。

## 实测数据(2026-07-28,138 组 / 104 节点)

| 槽位 | 节点数 | US/SG |
|---|---|---|
| P1 | 63 | 16 |
| P2 | 20 | 9 |
| P3 | 8 | 3 |
| P4 | 11 | **0** |

P4 无 US/SG → `P4-USSG` 空,但在 AI fallback 末位,前三个槽位 28 个 US/SG 兜底,空组自动跳过,无害。
两份成品均通过网关 mihomo v1.19.27 `mihomo -t` dry-run(0 error,无 deprecation)。
