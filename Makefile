PREFIX ?= /usr

install:
	install -d $(DESTDIR)$(PREFIX)/lib/claude-code
	install -d $(DESTDIR)$(PREFIX)/lib/claude-code/vendor/ripgrep/x64-linux
	install -d $(DESTDIR)$(PREFIX)/bin

	# Main application files
	install -m 644 staging/cli.js $(DESTDIR)$(PREFIX)/lib/claude-code/cli.js
	install -m 644 staging/package.json $(DESTDIR)$(PREFIX)/lib/claude-code/package.json
	install -m 644 staging/sdk-tools.d.ts $(DESTDIR)$(PREFIX)/lib/claude-code/sdk-tools.d.ts

	# WASM modules
	install -m 644 staging/resvg.wasm $(DESTDIR)$(PREFIX)/lib/claude-code/resvg.wasm
	install -m 644 staging/tree-sitter.wasm $(DESTDIR)$(PREFIX)/lib/claude-code/tree-sitter.wasm
	install -m 644 staging/tree-sitter-bash.wasm $(DESTDIR)$(PREFIX)/lib/claude-code/tree-sitter-bash.wasm

	# Ripgrep (Linux x64 only)
	install -m 755 staging/vendor/ripgrep/x64-linux/rg $(DESTDIR)$(PREFIX)/lib/claude-code/vendor/ripgrep/x64-linux/rg
	install -m 755 staging/vendor/ripgrep/x64-linux/ripgrep.node $(DESTDIR)$(PREFIX)/lib/claude-code/vendor/ripgrep/x64-linux/ripgrep.node
	install -m 644 staging/vendor/ripgrep/COPYING $(DESTDIR)$(PREFIX)/lib/claude-code/vendor/ripgrep/COPYING

	# Wrapper script
	install -m 755 scripts/wrapper.sh $(DESTDIR)$(PREFIX)/bin/claude
