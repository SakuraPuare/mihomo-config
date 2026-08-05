#!/usr/bin/env bash
# ============================================================
# build.sh —— 合并 src/ 片段 + 按 providers.conf 生成两级策略组
#             + 注入 secrets.local.env,产出 dist/<target>.yaml
# 用法: ./build.sh gateway | ./build.sh client
# 纯 bash,无外部依赖(yq/python 皆不需要)
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"

TARGET="${1:-}"
case "$TARGET" in
  gateway|client) ;;
  *) echo "用法: $0 gateway|client" >&2; exit 1 ;;
esac

SRC=src
OUT="dist/${TARGET}.yaml"
CONF=providers.conf
mkdir -p dist

# —— 载入 secrets(缺失则报错,绝不用占位符构建出真配置)——
if [[ -f secrets.local.env ]]; then
  # shellcheck disable=SC1091
  source secrets.local.env
else
  echo "!! 缺 secrets.local.env,请先: cp secrets.local.env.example secrets.local.env 并填值" >&2
  exit 1
fi

# —— 解析 providers.conf(每行: 槽位KEY  URL变量名  显示名变量名),保序=优先级 ——
KEYS=(); URLVARS=(); NAMEVARS=()
while read -r key urlvar namevar _rest; do
  [[ -z "${key:-}" || "${key:0:1}" == "#" ]] && continue
  KEYS+=("$key"); URLVARS+=("$urlvar"); NAMEVARS+=("${namevar:-}")
done < "$CONF"

# —— 各槽位的节点名前缀(供 filter 分段用)。节点名形如 "[WestData] 🇭🇰 Hong Kong | 01",
#    所以按 ^\[前缀\] 就能锁定某一家。方括号在正则里要转义。
PREFIX_RES=()
for i in "${!KEYS[@]}"; do
  _nv="${NAMEVARS[$i]}"; _n="${!_nv:-}"; _n="${_n:-${KEYS[$i]}}"
  PREFIX_RES+=("$_n")
done
[[ ${#KEYS[@]} -gt 0 ]] || { echo "!! providers.conf 无有效槽位" >&2; exit 1; }

# —— 健康检查公共字段 ——
HC_URL="https://www.gstatic.com/generate_204"
HC_INT=60
LB_STRATEGY="consistent-hashing"

# ============================================================
# 档位正则(mihomo 的 filter 只能按【节点名】正则,没法按延迟筛,故只能用地区表达)
# ============================================================
#
# JUNK:必须全局排除的非节点条目。混在池里流量落到就断:
#   [WestData] Traffic: 16.17 GB / 600 GB   [WestData] Expire: 2026-08-28
#   [Liangxin] 在线设备数量超过套餐允许值!  (整家订阅超限,3 条全是报错文案)
# ⚠️ "直连" 尤其危险:[Hive] 直连 是真·直连出口,混进出海链会裸穿 GFW
#    并泄露家里公网 IP(同 worker4 豁免那个坑的性质)。
JUNK_FILTER='(?i)Traffic|Expire|流量|到期|剩余|重置|套餐|订阅|官网|在线设备|复制|导入|直连|Direct'

# FAST_RE:高速档地区 = 港/台/日/新 + 美国。2026-07-31 以 github.com 为探测目标实测:
#   港 72-129ms  台 104-107ms  日 110-121ms  新 107ms  美 193-251ms
#   (对比其余:德 207 / 英 236 / 土 260 / 韩 358 / 智利 412 / 南非 426 / 阿根廷 440 / 巴西 355-1263)
# ⚠️ 台湾必须按【文字】匹配,不能用 🇨🇳 旗:P1 给台湾打 🇨🇳,而 Hive 给大陆节点也打 🇨🇳,
#    用旗子会把大陆节点误判进高速档。
FAST_RE='🇭🇰|香港|Hong ?Kong|\bHK\b|台湾|台北|Taiwan|\bTW\b|🇯🇵|日本|Japan|\bJP\b|🇸🇬|新加坡|Singapore|\bSG\b|🇺🇸|美国|United ?States|\bUS\b'

# USSG_RE:AI 专用(US/SG 防封号)
USSG_RE='🇺🇸|美国|United ?States|\bUS\b|🇸🇬|新加坡|Singapore|\bSG\b'

# RELAY_RE:名义地区骗人的中转。P3 的 🇭🇰中转 系列实测 975-1117ms,比阿根廷(440)还慢,
# 但名字里带 🇺🇸/🇭🇰 会被 FAST_RE 命中 → 必须用负向前查踢出高速档。
# mihomo 用 dlclark/regexp2,支持 lookahead(标准库 regexp 不支持)。
RELAY_RE='中转|relay'

# 字面反引号。mihomo 的 filter / exclude-filter 用反引号分隔多段正则,
# 且【多段 filter 会让节点按 filter 出现顺序排序】(groupbase.go:169-194)——
# 这正是本配置实现严格档位顺序的机制。
BT='`'

# ============================================================
# 生成 proxy-providers 段(每家独立,additional-prefix 隔离节点名)
# ============================================================
gen_providers() {
  echo "proxy-providers:"
  for i in "${!KEYS[@]}"; do
    local key="${KEYS[$i]}" urlvar="${URLVARS[$i]}" namevar="${NAMEVARS[$i]}"
    local url="${!urlvar:-}"
    local name="${!namevar:-}"; name="${name:-$key}"   # 显示名缺省用槽位KEY
    [[ -n "$url" ]] || { echo "!! secrets 里缺变量 $urlvar(槽位 $key)" >&2; exit 1; }
    cat <<EOF
  ${key}:
    type: http
    url: "${url}"
    interval: 86400
    proxy: DIRECT
    health-check:
      enable: true
      url: ${HC_URL}
      interval: ${HC_INT}
    override:
      additional-prefix: "[${name}] "
EOF
  done
}

# ============================================================
# 生成严格档位链的 filter
# ============================================================
# 机制:mihomo 的 filter 支持反引号分隔多段正则,且【节点按 filter 出现顺序排序】
#      (groupbase.go:169-194)。配合 type: fallback(逐节点判活,取第一个 alive),
#      就得到严格语义:前面所有节点全挂,才会用到后面的。
#
# 链序 = 高速档按机场优先级 → 其余按机场优先级:
#   P1高速 P2高速 P3高速 P4高速  P1其余 P2其余 P3其余 P4其余
#
# ⚠️ 高速段用负向前查 (?!.*中转) 踢掉 P3 的 🇭🇰中转 系列:它们名字带 🇺🇸/🇭🇰 会被
#    FAST_RE 命中,但实测 975-1117ms 比阿根廷(440)还慢。中转节点会落到"其余"段兜底。
#    mihomo 用 dlclark/regexp2,支持 lookahead(Go 标准库 regexp 不支持)。
gen_chain_filter() {
  local out="" key pre
  # 第一段:各家高速节点(排除中转)
  for i in "${!KEYS[@]}"; do
    pre="${PREFIX_RES[$i]}"
    out+="${out:+${BT}}(?i)^\\[${pre}\\](?!.*(?:${RELAY_RE})).*(?:${FAST_RE})"
  done
  # 第二段:各家其余节点(前缀匹配即可,兜底不再挑地区)
  for i in "${!KEYS[@]}"; do
    pre="${PREFIX_RES[$i]}"
    out+="${BT}(?i)^\\[${pre}\\]"
  done
  printf '%s' "$out"
}

# AI 专用链:各家 US/SG,按机场优先级(排除中转)
gen_ai_filter() {
  local out="" pre
  for i in "${!KEYS[@]}"; do
    pre="${PREFIX_RES[$i]}"
    out+="${out:+${BT}}(?i)^\\[${pre}\\](?!.*(?:${RELAY_RE})).*(?:${USSG_RE})"
  done
  printf '%s' "$out"
}

# ============================================================
# 生成 proxy-groups 段(两级拓扑)
# ============================================================
gen_groups() {
  echo "proxy-groups:"

  # ---- 顶层:🚀 节点选择(手动高于一切;默认=⚡自动)----
  echo "  - name: 🚀 节点选择"
  echo "    type: select"
  echo "    proxies:"
  echo "      - ⚡ 自动"
  echo "      - 🔀 高速均衡"
  echo "      - DIRECT"
  echo "    use:"
  for key in "${KEYS[@]}"; do echo "      - ${key}"; done

  # ---- ⚡ 自动:两档 fallback ----
  # 先按机场优先级走完【全部高速档】,再按机场优先级走【其他档】。
  # ⚠️ mihomo 的 fallback 语义做不到「整档全挂才降级」:findAliveProxy 读的是缓存存活态,
  #    而 fallback 探一个成员组 = 经该组真拨一次(组内 consistent-hashing 只命中一个节点),
  #    那一个节点抖 → 整组判死。见 KB network/gateway-mihomo-two-tier-fallback。
  #    本结构的作用是把【危害】压掉:要掉到其他档,得所有高速组同时探测失败。
  echo "  - name: ⚡ 自动"
  echo "    type: fallback"
  echo "    url: ${HC_URL}"
  echo "    interval: ${HC_INT}"
  echo "    empty-fallback: REJECT"
  echo "    filter: '$(gen_chain_filter)'"
  echo "    exclude-filter: '${JUNK_FILTER}'"
  echo "    use:"
  for key in "${KEYS[@]}"; do echo "      - ${key}"; done

  # ---- 🤖 AI:跨家 fallback,每家只用 US/SG 均衡组 ----
  # ---- 🤖 AI:同样严格语义,各家 US/SG 按优先级(防封号)----
  echo "  - name: 🤖 AI"
  echo "    type: fallback"
  echo "    url: ${HC_URL}"
  echo "    interval: ${HC_INT}"
  echo "    empty-fallback: REJECT"
  echo "    filter: '$(gen_ai_filter)'"
  echo "    exclude-filter: '${JUNK_FILTER}'"
  echo "    use:"
  for key in "${KEYS[@]}"; do echo "      - ${key}"; done

  # ---- 🔀 高速均衡:仅供手动选。跨 4 家的高速节点做 load-balance,牺牲严格语义换带宽聚合 ----
  # ⚡自动(fallback)永远只用一个节点、不聚合带宽;需要多节点并发时手动切到这个组。
  cat <<EOF
  - name: 🔀 高速均衡
    type: load-balance
    strategy: ${LB_STRATEGY}
    url: ${HC_URL}
    interval: ${HC_INT}
    lazy: true
    max-failed-times: 3
    empty-fallback: REJECT
    filter: '(?i)^(?!.*(?:${RELAY_RE})).*(?:${FAST_RE})'
    exclude-filter: '${JUNK_FILTER}'
    use:
EOF
  for key in "${KEYS[@]}"; do echo "      - ${key}"; done
  return 0
}

# 旧的每家三组实现已废弃(方案二),保留函数体不再调用
gen_groups_legacy() {
  # ---- 每家三个 load-balance 组:高速档 + 其他档 + US/SG(给 AI)----
  #
  # ⚠️⚠️ 每组必须显式 empty-fallback: REJECT。
  # mihomo groupbase.go 里 `if len(proxies)==0 { return EmptyFallback() }`,而默认
  # EmptyFallback = COMPATIBLE,且 NewCompatible() 返回的是 *Direct —— 即
  # 【filter 筛不到节点的组会静默变成直连】。DIRECT 永远 alive,于是它会稳稳占住
  # fallback 链、永不降级,出海流量裸穿 GFW 并泄露家里公网 IP。
  # 本配置必然出现空组:Hive 只有巴西/国内/直连 → P4-高速 空;Liangxin 整家死透 → 两档全空。
  # 改成 REJECT 后,空组=明确拒绝(loud fail),不会静默裸奔。
  for key in "${KEYS[@]}"; do
    # 高速档:港台日新美,排掉垃圾条目与名义地区骗人的"中转"
    cat <<EOF
  - name: ${key}-高速
    type: load-balance
    strategy: ${LB_STRATEGY}
    url: ${HC_URL}
    interval: ${HC_INT}
    lazy: true
    max-failed-times: 3
    empty-fallback: REJECT
    filter: '${FAST_FILTER}'
    exclude-filter: '${JUNK_FILTER}\`${FAST_EXCLUDE}'
    use:
      - ${key}
EOF
    # 其他档:兜底。只排垃圾条目,【不】排高速节点 ——
    # 它的职责是"高速档全挂时还能上网",宁可与高速档重叠,也不要因为筛空而变 REJECT。
    cat <<EOF
  - name: ${key}-其他
    type: load-balance
    strategy: ${LB_STRATEGY}
    url: ${HC_URL}
    interval: ${HC_INT}
    lazy: true
    max-failed-times: 3
    empty-fallback: REJECT
    exclude-filter: '${JUNK_FILTER}'
    use:
      - ${key}
EOF
    # US/SG 均衡(给 🤖 AI 用,防封号)
    cat <<EOF
  - name: ${key}-USSG
    type: load-balance
    strategy: ${LB_STRATEGY}
    url: ${HC_URL}
    interval: ${HC_INT}
    lazy: true
    max-failed-times: 3
    empty-fallback: REJECT
    filter: '(?i)美国|新加坡|🇺🇸|🇸🇬|\bUS\b|United ?States|SG|Singapore'
    exclude-filter: '${JUNK_FILTER}\`${FAST_EXCLUDE}'
    use:
      - ${key}
EOF
  done
}

# —— 自定义直连域名(custom-direct.list,可选,本地不进 repo)——
CUSTOM_LIST=custom-direct.list
CUSTOM_DOMAINS=()
if [[ -f "$CUSTOM_LIST" ]]; then
  while read -r dom _rest; do
    [[ -z "${dom:-}" || "${dom:0:1}" == "#" ]] && continue
    CUSTOM_DOMAINS+=("$dom")
  done < "$CUSTOM_LIST"
fi

# 生成注入内容(缩进对齐宿主行);无自定义域名则注入空(标记行删掉)
gen_custom_rules() {   # rules 段: "  - DOMAIN-SUFFIX,x,DIRECT"
  for d in "${CUSTOM_DOMAINS[@]}"; do echo "  - DOMAIN-SUFFIX,${d},DIRECT"; done
}
gen_custom_filter() {  # fake-ip-filter 段: '    - "+.x"'
  for d in "${CUSTOM_DOMAINS[@]}"; do echo "    - \"+.${d}\""; done
}

# ============================================================
# 组装:entry(含 secret 注入) + _general + providers + groups + _rules
# ============================================================
{
  # entry 段:注入 controller secret(仅 gateway 用到)
  sed "s|__CONTROLLER_SECRET__|${CONTROLLER_SECRET:-change-me}|g" "$SRC/entry-${TARGET}.yaml"
  echo
  cat "$SRC/_general.yaml"; echo
  gen_providers; echo
  gen_groups; echo
  cat "$SRC/_rules.yaml"
} > "$OUT.tmp"

# 用 awk 把两个标记行替换成生成内容(无域名则整行删除)
CUSTOM_RULES="$(gen_custom_rules)"
CUSTOM_FILTER="$(gen_custom_filter)"
awk -v rules="$CUSTOM_RULES" -v filt="$CUSTOM_FILTER" '
  /__CUSTOM_DIRECT_RULES__/  { if (length(rules)) print rules; next }
  /__CUSTOM_DIRECT_FILTER__/ { if (length(filt))  print filt;  next }
  { print }
' "$OUT.tmp" > "$OUT"
rm -f "$OUT.tmp"

echo "✓ 生成 $OUT ($(wc -l < "$OUT") 行, ${#KEYS[@]} 家机场)"

# —— 泄漏自检:产物不该出现在 git 追踪(dist/ 已 gitignore),这里再兜底扫 secret 形态 ——
if grep -qE 'change-me|__CONTROLLER_SECRET__' "$OUT"; then
  echo "⚠ 警告:$OUT 含占位/默认 secret,请检查 secrets.local.env" >&2
fi
