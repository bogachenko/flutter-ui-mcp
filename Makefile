MCP_PORT ?= 1985
VM_SERVICE_FILE ?= $(HOME)/.cache/flutter-ui-mcp/vmservice.url

.PHONY: mcp-run

mcp-run:
	dart run marionette_mcp:marionette_mcp \
	  --http-port $(MCP_PORT) \
	  --vmservice-file "$(VM_SERVICE_FILE)"
