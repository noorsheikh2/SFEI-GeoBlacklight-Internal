# Technical Specification & Plan: Geoblacklight Sidecar Images Integration
**Issue Reference:** [Issue #10: Install and Configure Geoblacklight Sidecar Images Plugin](https://github.com/noorsheikh2/SFEI-GeoBlacklight-Internal/issues/10)  
**Branch:** `10-geoblacklight-sidecar-images`  
**Date:** November 2026  
**Status:** Draft / In Review  

---

## 1. Overview & Goals
The goal of this enhancement is to install and configure the [`geoblacklight_sidecar_images`](https://github.com/geoblacklight/geoblacklight_sidecar_images) plugin into the SFEI GeoBlacklight internal application. This will display preview/thumbnail images alongside search result lists and on item show pages.

Key requirements:
1. Support image filenames provided in Solr documents ingested via an automated cron job.
2. Resolve image files reliably in all environments (development, CI, and containerized production).
3. Integrate `geoblacklight_sidecar_images` and Active Storage to cache and serve images.
4. Provide comprehensive documentation on adding images, Solr schema updates, and operational tasks.

---

## 2. Codebase & Environment Analysis

### 2.1 Solr Schema & Ingestion Discovery
* **Ingestion Script Found:** `sheet_to_solr.py`
  * Pulls from Google Sheet: `1Kv6W_hUBSz8dmYAqxvS_J_Y5UWXCgTYoaZSkK5WgYSs`
  * Generates Solr documents directly via Solr `/update` JSON API.
* **Exact Image Field Name in Solr:**  
  **`sfei_image_name_s`**
  * Example values found in live data:
    * `"BHM2020v13.png"`
    * `"lower_coyote_creek.png"`
    * `"ACCESS-CM2_historical_ssp245_climate_projections.png"`
* **Solr Dynamic Schema Support:**  
  `schema.xml` defines `<dynamicField name="*_s" type="string" stored="true" indexed="true"/>`.  
  Because `sfei_image_name_s` ends with `_s`, **no schema changes are needed in Solr**. It is already indexed and stored properly.

### 2.2 Image Storage & Ingestion Strategy (Google Drive Sync to Server Disk)
* **Image Source:**  
  Images reside in the SFEI Google Drive folder:  
  `https://drive.google.com/drive/folders/17D5TLgcpPV83MimUhCafa9roncOSgHsa`
* **Cron Sync to Server (`public/thumbnails/`):**
  * The automated ingestion job (`sheet_to_solr.py` / cron) will be enhanced with an image sync section that downloads referenced image files from Google Drive into the server's `public/thumbnails/` directory.
  * **File Caching & Immutability Rule:** Files that already exist in `public/thumbnails/` will **not** be re-copied/downloaded. If staff need to change or update an image, they must upload it with a new filename (e.g. `my_image_v2.png`) and update the filename in the Google Sheet. This new name is also required because `geoblacklight_sidecar_images` caches images permanently via Active Storage state tracking and will not re-fetch or serve a new file if it retains the same name.
  * **Images are NOT tracked in Git:** Image binaries remain excluded from git history (`.gitignore`), keeping the repository lightweight. A `.keep` file maintains the directory structure.
  * **Static asset serving:** Rails / reverse proxy serves the synced raw images directly at `http://<host>/thumbnails/<filename>` with zero proxy overhead.
* **Active Storage Architecture:**
  * **Storage Service:** Local Disk (`:local` service in `config/storage.yml`), storing processed attachments under `storage/`.
  * **Delivery Route:** Rails storage proxy mode (`config.active_storage.resolve_model_to_route = :rails_storage_proxy`) to stream images with long-term HTTP cache headers, avoiding 302 redirect roundtrips on search results.
  * **Container Persistence:** `/rails/storage` and `/rails/public/thumbnails` will be persisted via Docker volumes in production so synced files and sidecar caches survive container restarts.

---

## 3. Architecture & Data Flow

```mermaid
flowchart TD
    subgraph Data Ingestion
        A["Google Sheet (Metadata Upload Doc)"] -->|sheet_to_solr.py| B[(Solr Index)]
        B -->|Field: sfei_image_name_s| C[Solr Document]
    end

    subgraph Image Assets
        IMG["Google Drive / Images Folder"] --> |sheet_to_solr.py| DIR[public/thumbnails/]
        DIR -->|Served as static asset| URL["http://host/thumbnails/sfei_image_name_s"]
    end

    subgraph Rails Application
        C --> D[geoblacklight_sidecar_images]
        URL --> D
        D -->|Active Storage attachment| DB[(SQLite / Sidecar Table)]
        DB --> E[SearchResultComponent View]
        E -->|Render image thumbnail| UI[User Browser Search Results]
    end
```

### 3.1 Field Mapping Flow
1. `sheet_to_solr.py` indexes each record into Solr with its image filename in **`sfei_image_name_s`** (e.g. `"BHM2020v13.png"`).
2. The application configuration points `GBLSI_THUMBNAIL_FIELD` to `sfei_image_name_s`.
3. Because the field contains a filename rather than a full URL, we configure the image harvester / URL helper to resolve filenames against `/thumbnails/` (e.g., `/thumbnails/#{document['sfei_image_name_s']}`).
4. `geoblacklight_sidecar_images` attaches the image to the `SolrDocumentSidecar` Active Record model.
5. In search results and show views, GeoBlacklight displays the sidecar image.

---

## 4. Step-by-Step Implementation Plan

### Phase 1: Environment & Branch Setup (Completed)
- [x] Create feature branch `10-geoblacklight-sidecar-images`.
- [x] Create `docs/specs/` directory and author this specification.

### Phase 2: Plugin & Storage Setup
- [ ] Add `gem "geoblacklight_sidecar_images"` to `Gemfile`.
- [ ] Run `bundle install`.
- [ ] Run `bin/rails generate geoblacklight_sidecar_images:install`.
- [ ] Review and run database migrations (`bin/rails db:migrate`).
- [ ] Ensure Active Storage is configured in `config/storage.yml` (local disk storage for development and production).

### Phase 3: Image Directory & Serving Configuration
- [ ] Create repository directory `public/thumbnails/` with a `.keep` file, adding `public/thumbnails/*` (except `.keep`) to `.gitignore`.
- [ ] Update `config/settings.yml` with:
  ```yaml
  GBLSI_THUMBNAIL_FIELD: 'sfei_image_name_s'
  ```
- [ ] Configure filename-to-URL normalization so that when Solr contains `BHM2020v13.png`, the sidecar harvester resolves it at `/thumbnails/BHM2020v13.png`.

### Phase 4: Harvesting & Ingestion Integration
- [ ] Test the rake task `rake gblsci:images:harvest_all` on sample documents.
- [ ] Provide a helper task or cron hook to trigger image harvesting automatically after Solr document indexing.

### Phase 5: Testing & Verification
- [ ] Add unit/model test for `SolrDocumentSidecar` and thumbnail URL resolution.
- [ ] Verify image rendering on search result cards and document show pages.
- [ ] Verify Docker build (`docker build .`) packages the `public/thumbnails/` directory.
- [ ] Run CI checks (`bin/brakeman`, `bin/rubocop`, `bin/rails test`).

### Phase 6: Operational Documentation
- [ ] Add `docs/IMAGE_MANAGEMENT.md` with instructions on:
  - How staff add new images to the Google Drive folder.
  - Image update policy: always use a new filename when changing/updating an image (existing files are not re-downloaded).
  - How the Google Sheet metadata corresponds to Solr (`sfei_image_name_s`).
  - How the sync and sidecar harvesting runs via cron.
  - Troubleshooting tips for missing images.
