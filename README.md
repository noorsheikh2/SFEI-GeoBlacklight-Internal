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

### 4. (Optional) Ingest Metadata and Sync Images
To sync live metadata from the SFEI Google Sheet and referenced thumbnail images from Google Drive into Solr and `public/thumbnails/`:
```bash
# Dry run first (prints JSON records without modifying Solr):
python3 scripts/sheet_to_solr.py --dry-run

# Ingest metadata and sync images:
python3 scripts/sheet_to_solr.py

# Process & attach sidecar thumbnail images in GeoBlacklight:
bin/rails gblsci:images:harvest_all
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

---

## Image Management (Preview & Thumbnail Images)

GeoBlacklight displays curated preview and thumbnail images beside search results and on record show pages using the `geoblacklight_sidecar_images` plugin backed by Rails Active Storage.

### How Images Work in the System
1. **Source of Truth:** Images are maintained by SFEI staff in the shared Google Drive folder:
   [SFEI Images Folder](https://drive.google.com/drive/folders/17D5TLgcpPV83MimUhCafa9roncOSgHsa).
2. **Metadata Linkage:** In the [Metadata Upload Doc (Google Sheet)](https://docs.google.com/spreadsheets/d/1Kv6W_hUBSz8dmYAqxvS_J_Y5UWXCgTYoaZSkK5WgYSs), staff provide the exact filename in the **`sfei_image_name_s`** column (e.g. `BHM2020v13.png`).
3. **Automated Sync (`scripts/sheet_to_solr.py`):**
   - Ingestion downloads missing images from Google Drive into `public/thumbnails/`.
   - Records are indexed into Solr containing `sfei_image_name_s`.
4. **Sidecar Attachment (`rake gblsci:images:harvest_all`):**
   - Active Storage attaches local images from `public/thumbnails/` to `SolrDocumentSidecar` records.
   - Attachments are served via Rails storage proxy routes with long-term HTTP caching.

### Step-by-Step: Adding New Images
1. **Upload File:** Upload the graphic file (`.png`, `.jpg`, `.webp`) to the [SFEI Images Google Drive folder](https://drive.google.com/drive/folders/17D5TLgcpPV83MimUhCafa9roncOSgHsa).
2. **Update Metadata Sheet:** Open the [Metadata Upload Doc](https://docs.google.com/spreadsheets/d/1Kv6W_hUBSz8dmYAqxvS_J_Y5UWXCgTYoaZSkK5WgYSs). In the row corresponding to the dataset, enter the exact filename (including extension, case-sensitive) in the `sfei_image_name_s` column.
3. **Wait for Cron Sync or Trigger Manually:**
   ```bash
   python3 scripts/sheet_to_solr.py
   bin/rails gblsci:images:harvest_all
   ```

### Critical Image Update Policy: Immutability Rule
> **IMPORTANT:** Always use a **new filename** when updating or replacing an existing image (e.g., `wetlands_map_v2.png` instead of `wetlands_map.png`).
> 
> *Why?*
> 1. **Drive Sync Caching:** The sync script skips files that already exist on disk in `public/thumbnails/` to avoid redundant re-downloads.
> 2. **Active Storage & Browser Caching:** `geoblacklight_sidecar_images` tracks attachment state in the database and caches files permanently. If a file retains the same filename, neither Rails Active Storage nor client browser caches will re-fetch the new content.

### Automated Cron Job Workflow
In staging and production, the ingestion and image harvesting process runs automatically via cron:
```bash
# Sync metadata and images, harvest new sidecars, and retry any placeheld records:
cd /rails && python3 scripts/sheet_to_solr.py && bin/rails gblsci:images:harvest_all RAILS_ENV=production && bin/rails gblsci:images:harvest_retry RAILS_ENV=production >> /rails/log/cron_sync.log 2>&1
```
> **Why all three steps?**  
> We sync the images and we must "harvest" them for sidecar. The retry step is needed in case the image was not yet uploaded when the sheet was processed with it.

### Production Persistence Requirements
When deploying containerized instances (Docker / Podman / Kubernetes), ensure persistent volumes are mounted for:
* `/rails/storage` - Active Storage attachment blobs.
* `/rails/public/thumbnails` - Raw synced image cache from Google Drive.
* `/rails/db` - SQLite database storing sidecars and state transitions.

Ensure directories are owned by the runtime container user (`rails` / UID 1000).

### Troubleshooting Missing Images
* **Thumbnail displays placeholder map pin on search results:**
  - Verify if `sfei_image_name_s` is populated in Solr for the record.
  - Check if the file exists in `public/thumbnails/<filename>`.
  - Check file permissions: ensure the web server process has read permissions for `public/thumbnails/`.
  - Note that Linux filesystems are **case-sensitive**: `My_Image.PNG` does not match `my_image.png`.
* **Image was uploaded after initial harvest failed / was placeheld:**
  - If a record was harvested before its image existed on disk, its state was set to `:placeheld`.
  - `rake gblsci:images:harvest_all` skips records that are already in `:placeheld` or `:succeeded`.
  - To force re-harvesting of placeheld records once images are downloaded:
    ```bash
    bin/rails gblsci:images:harvest_retry
    ```
* **Check harvest logs:**
  - Inspect `log/image_service_<environment>.log` for detailed attachment messages, HTTP statuses, and transition errors.
