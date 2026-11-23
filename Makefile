.PHONY: local-run solr-start solr-stop sync test help

SHELL := /bin/bash
SOLR_URL := http://127.0.0.1:8983/solr/blacklight-core/select?q=*:*&rows=0

help:
	@echo "Available targets:"
	@echo "  make local-run   - Check/start Solr, prepare DB, sync sheet & images, harvest, and start Rails server"
	@echo "  make dry-run     - Inspect Google Sheet for data issues/warnings without modifying Solr"
	@echo "  make solr-start  - Start the Solr container (Docker or Podman)"
	@echo "  make solr-stop   - Stop the Solr container"
	@echo "  make sync        - Ingest Google Sheet metadata and harvest images into Active Storage"
	@echo "  make test        - Run the test suite"

dry-run:
	python3 scripts/sheet_to_solr.py --dry-run --no-json

solr-start:
	@if curl -sf "$(SOLR_URL)" > /dev/null; then \
		echo "✓ Solr is already running on port 8983"; \
	elif command -v docker > /dev/null 2>&1; then \
		echo "Starting Solr via docker compose..."; \
		docker compose up -d solr; \
	elif command -v podman > /dev/null 2>&1; then \
		echo "Starting Solr via podman..."; \
		podman compose up -d solr 2>/dev/null || podman-compose up -d solr 2>/dev/null || podman run -d --name sfei-solr -p 8983:8983 -v "$$PWD/solr/conf:/opt/solr/conf:Z" solr:9.6.1 solr-precreate blacklight-core /opt/solr/conf -Xms256m -Xmx512m; \
	else \
		echo "Neither docker nor podman found in PATH. If Solr is already running elsewhere, continuing..."; \
	fi
	@echo "Waiting for Solr to become ready..."
	@count=0; \
	until curl -sf "$(SOLR_URL)" > /dev/null; do \
		count=$$((count + 1)); \
		if [ $$count -gt 20 ]; then \
			echo "WARNING: Solr did not respond within 20s. Continuing..."; \
			break; \
		fi; \
		sleep 1; \
	done
	@if curl -sf "$(SOLR_URL)" > /dev/null; then echo "✓ Solr is ready!"; fi

solr-stop:
	@if command -v docker > /dev/null 2>&1; then \
		docker compose down; \
	elif command -v podman > /dev/null 2>&1; then \
		podman compose down 2>/dev/null || podman-compose down 2>/dev/null || podman stop sfei-solr 2>/dev/null || true; \
	fi

sync:
	@echo "Syncing Google Sheet metadata and images..."
	python3 scripts/sheet_to_solr.py
	@echo "Harvesting dataset images into Active Storage..."
	bin/rails sfei:images:harvest_all

local-run: solr-start
	@echo "Preparing database..."
	bin/rails db:prepare
	@echo "Syncing metadata from Google Sheet into Solr..."
	-python3 scripts/sheet_to_solr.py
	@echo "Harvesting images into Active Storage..."
	-bin/rails sfei:images:harvest_all
	@echo ""
	@echo "=================================================="
	@echo " Starting Rails server on http://localhost:3000   "
	@echo "=================================================="
	@echo ""
	bin/rails server

test:
	bin/rails test
