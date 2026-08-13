
.PHONY: install-hooks
install-hooks:  ## install the pre-push CI-parity gate
	@printf '#!/bin/bash\nexec bash "$$(git rev-parse --show-toplevel)/scripts/pre-push-gates.sh" "$$@"\n' > .git/hooks/pre-push
	@chmod +x .git/hooks/pre-push
	@echo "pre-push gate installed"
