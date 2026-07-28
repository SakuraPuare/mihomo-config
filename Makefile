.PHONY: all gateway client clean check

all: gateway client

gateway:
	@./build.sh gateway

client:
	@./build.sh client

# 语法校验:优先 mihomo -t,退而用 python(需 pyyaml),都没有则跳过
check: all
	@for f in dist/gateway.yaml dist/client.yaml; do \
		if command -v mihomo >/dev/null 2>&1; then \
			mihomo -t -f $$f && echo "✓ $$f 通过 mihomo 校验"; \
		elif python3 -c "import yaml" >/dev/null 2>&1; then \
			python3 -c "import yaml,sys; yaml.safe_load(open('$$f')); print('✓ $$f YAML 语法 OK')"; \
		else \
			echo "… 无 mihomo/pyyaml,跳过 $$f 校验(可在网关 mihomo -t 验)"; \
		fi; \
	done

clean:
	@rm -rf dist && echo "已清 dist/"
