.PHONY: build test agent-test demo backtest
build:        ; forge build
test:         ; forge test -vv
agent-test:   ; cd agent && PYTHONPATH=. python3 -m pytest -q
backtest:     ; cd agent && PYTHONPATH=. python3 -m sentinel.backtest
demo:         ; bash scripts/demo_local.sh
