# mihomo-config

模块化、零维护的通用 [mihomo](https://github.com/MetaCubeX/mihomo) 配置。
一份源生成两份成品:**VyOS 网关 iptables REDIRECT** + **全平台客户端 TUN**。

- 多机场按**优先级 fallback**,同家内部 load-balance,整家挂自动切下一家
- **手动高于一切**:手动选节点即全局生效;AI 独立锁 US/SG 防封号
- **极简规则**(8 条):私有/国内直连 + AI 走 US/SG + 其余走代理
- **DNS 不泄漏**(fake-ip 远端解析)+ **冷启动自愈**(纯 IP DoH 解析节点域名)+ IPv6 全关回落 v4
- geodata / 订阅 / rule-set 运行时自更新,日常零维护

## 快速开始

```bash
cp secrets.local.env.example secrets.local.env   # 填 4 家订阅 URL + 面板 secret
vim secrets.local.env
make            # 生成 dist/gateway.yaml + dist/client.yaml
make check      # 语法校验(有 mihomo/pyyaml 时)
```

## 加/删机场、调优先级

只改 `providers.conf`(每行一家,**行序=fallback 优先级**),然后 `make`。
build 脚本自动为每家生成 `<家>-均衡` 和 `<家>-USSG` 两个组并接入两级 fallback。

## 目录

```
providers.conf          机场清单 + 优先级 —— 唯一需要人改的文件
secrets.local.env       真实订阅 URL + secret(gitignore,不进 repo)
src/_general.yaml       DNS / sniffer / 全局调优(端口无关)
src/_rules-gateway.yaml 网关规则(split-DNS 下自有域名直连)
src/_rules-client.yaml  客户端/VPS 规则(自有域名默认走代理)
src/entry-gateway.yaml  网关差异(redir-port / 面板 secret 占位)
src/entry-client.yaml   客户端差异(TUN / dns-hijack)
build.sh                拼装 + 按 providers.conf 生成策略组 + 注入 secrets
dist/                   成品(gitignore,含注入后真实 URL)
docs/design.md          完整设计与取舍
```

## 部署

- **网关**:`dist/gateway.yaml` → VyOS `/config/mihomo/config.yaml`,用控制器 API 热重载。
  ⚠️ 绝不裸 kill mihomo；iptables REDIRECT 仍会劫持流量,进程退出会让全屋出海黑洞。
- **客户端**:`dist/client.yaml` 托管到你的订阅服务器,手机/电脑填订阅 URL。

## 安全

订阅 URL / 面板 secret 只在本地 `secrets.local.env`,**不进 repo**。
clone 后必须自建 `secrets.local.env` 才能构建出可用配置。
