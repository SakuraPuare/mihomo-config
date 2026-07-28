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
[[ ${#KEYS[@]} -gt 0 ]] || { echo "!! providers.conf 无有效槽位" >&2; exit 1; }

# —— 健康检查公共字段 ——
HC_URL="https://www.gstatic.com/generate_204"
HC_INT=60
LB_STRATEGY="consistent-hashing"

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
# 生成 proxy-groups 段(两级拓扑)
# ============================================================
gen_groups() {
  echo "proxy-groups:"

  # ---- 顶层:🚀 节点选择(手动高于一切;默认=⚡自动)----
  echo "  - name: 🚀 节点选择"
  echo "    type: select"
  echo "    proxies:"
  echo "      - ⚡ 自动"
  for key in "${KEYS[@]}"; do echo "      - ${key}-均衡"; done
  echo "      - DIRECT"
  echo "    use:"
  for key in "${KEYS[@]}"; do echo "      - ${key}"; done

  # ---- ⚡ 自动:跨家 fallback,按 providers.conf 顺序 ----
  echo "  - name: ⚡ 自动"
  echo "    type: fallback"
  echo "    url: ${HC_URL}"
  echo "    interval: ${HC_INT}"
  echo "    proxies:"
  for key in "${KEYS[@]}"; do echo "      - ${key}-均衡"; done

  # ---- 🤖 AI:跨家 fallback,每家只用 US/SG 均衡组 ----
  echo "  - name: 🤖 AI"
  echo "    type: fallback"
  echo "    url: ${HC_URL}"
  echo "    interval: ${HC_INT}"
  echo "    proxies:"
  for key in "${KEYS[@]}"; do echo "      - ${key}-USSG"; done

  # ---- 每家两个 load-balance 组:全节点均衡 + US/SG 均衡 ----
  for key in "${KEYS[@]}"; do
    # 全节点均衡
    cat <<EOF
  - name: ${key}-均衡
    type: load-balance
    strategy: ${LB_STRATEGY}
    url: ${HC_URL}
    interval: ${HC_INT}
    lazy: true
    max-failed-times: 3
    use:
      - ${key}
EOF
    # US/SG 均衡(filter 只留美国/新加坡节点)
    cat <<EOF
  - name: ${key}-USSG
    type: load-balance
    strategy: ${LB_STRATEGY}
    url: ${HC_URL}
    interval: ${HC_INT}
    lazy: true
    max-failed-times: 3
    filter: "(?i)美国|新加坡|🇺🇸|🇸🇬|\\\\bus\\\\b|unitedstates|united states|sg|singapore"
    use:
      - ${key}
EOF
  done
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
} > "$OUT"

echo "✓ 生成 $OUT ($(wc -l < "$OUT") 行, ${#KEYS[@]} 家机场)"

# —— 泄漏自检:产物不该出现在 git 追踪(dist/ 已 gitignore),这里再兜底扫 secret 形态 ——
if grep -qE 'change-me|__CONTROLLER_SECRET__' "$OUT"; then
  echo "⚠ 警告:$OUT 含占位/默认 secret,请检查 secrets.local.env" >&2
fi
