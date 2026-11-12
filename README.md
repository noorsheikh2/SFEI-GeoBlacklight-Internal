# SFEI GeoBlacklight

Internal GeoBlacklight catalog for the San Francisco Estuary Institute (SFEI).

---

## Prerequisites

Ensure you have the following installed locally:
* **Ruby:** `3.3.6` (managed via `rbenv`, `asdf`, or `rvm`)
* **Bundler:** `gem install bundler`
* **Container Engine:** Docker or Podman (with Compose support) to run the Solr search engine container
* **SQLite3** & **libvips** (for image processing)
  * macOS: `brew install libvips sqlite`
  * Ubuntu/Debian: `sudo apt install libvips42 sqlite3`

---

## Local Development Quickstart

### 1. Install Dependencies
```bash
bundle install
```

### 2. Start the Solr Container
GeoBlacklight requires Apache Solr. A pre-configured Solr core is provided via Docker / Podman Compose:
```bash
# Using Docker:
docker compose up -d solr

# Using Podman:
podman compose up -d solr
```
*Solr will be accessible at: `http://localhost:8983/solr/#/blacklight-core`*

### 3. Initialize the Database
Prepare the local SQLite database and run any pending migrations:
```bash
bin/rails db:prepare
```

### 4. (Optional) Ingest Metadata into Solr
To sync live data from the SFEI Google Sheet into your local Solr core:
```bash
# Dry run first (prints JSON records without modifying Solr):
python3 ../sheet_to_solr.py --dry-run

# Ingest into local Solr:
python3 ../sheet_to_solr.py
```

### 5. Start the Rails Server
```bash
bin/rails server
```
Open your browser to: **`http://localhost:3000`**

---

## Stopping Services

To stop the Rails server:
* Press `Ctrl + C` in the terminal running the server.

To stop the Solr container:
```bash
docker compose down
```

---

## Running Tests & Quality Checks

Run the automated test suite and security/style linters:
```bash
# Run unit and system tests
bin/rails test
bin/rails test:system

# Security scan
bin/brakeman

# Ruby style linting
bin/rubocop
```

---

## Production Docker Commands

The included `Dockerfile` builds a production-ready, self-contained container.

### Build the Docker Image
```bash
docker build -t sfei-geoblacklight .
```

### Run the Docker Container Locally
```bash
docker run -d \
  -p 3000:3000 \
  --name sfei-geoblacklight \
  -e RAILS_MASTER_KEY=$(cat config/master.key) \
  sfei-geoblacklight
```

### Stop and Remove the Container
```bash
docker stop sfei-geoblacklight
docker rm sfei-geoblacklight
```

---

## Production Podman Commands

If using Podman instead of Docker:

### Build the Image
```bash
podman build -t sfei-geoblacklight .
```

### Run the Container Locally
```bash
podman run -d \
  -p 3000:3000 \
  --name sfei-geoblacklight \
  -e RAILS_MASTER_KEY=$(cat config/master.key) \
  sfei-geoblacklight
```

### Stop and Remove the Container
```bash
podman stop sfei-geoblacklight
podman rm sfei-geoblacklight
```

> **Note for macOS Podman users:** Ensure your Podman machine is running first:
> ```bash
> podman machine start
> ```
