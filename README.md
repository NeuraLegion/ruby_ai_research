# Product Catalog API

A Sinatra-based REST API for managing a product catalog, backed by PostgreSQL.

## Getting Started

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) and [Docker Compose](https://docs.docker.com/compose/install/)

### Run the Application

```bash
docker compose up --build
```

This starts two services:

| Service | Description | Port |
|---------|-------------|------|
| **app** | Sinatra API server (Puma) | `4567` |
| **db** | PostgreSQL 16 | `5432` |

The database is automatically migrated and seeded with sample products on first boot.

### Generate an Auth Token

Most endpoints require a Bearer token. Generate one with:

```bash
docker compose exec app ruby generate_token.rb
```

Use the token in requests:

```bash
TOKEN=$(docker compose exec -T app ruby generate_token.rb)
```

Alternatively, call the `/auth` endpoint:

```bash
TOKEN=$(curl -s -X POST http://localhost:4567/auth | jq -r '.token')
```

## API Endpoints

### Public

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check (database status, memory, uptime) |
| `POST` | `/auth` | Obtain a Bearer token |

### Authenticated (requires `Authorization: Bearer <token>`)

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/v2/products` | List products (paginated) |
| `GET` | `/api/v2/products/filter` | Filter products (advanced query builder) |
| `GET` | `/api/v2/products/:id` | Get a single product |
| `POST` | `/api/v2/products` | Create a product |
| `DELETE` | `/api/v2/products/:id` | Delete a product |
| `GET` | `/api/v2/search?q=<query>` | Search products by name or description |

### Query Parameters for `GET /api/v2/products`

| Param | Description |
|-------|-------------|
| `category` | Filter by category (e.g. `electronics`, `furniture`, `books`) |
| `min_price` | Minimum price filter |
| `sort_by` | Sort column — one of `name`, `price`, `created_at`, `rating` |
| `page` | Page number (default: 1) |
| `per_page` | Results per page (default: 25, max: 100) |

## Example Requests

```bash
# Health check
curl http://localhost:4567/health

# List electronics sorted by price
curl -H "Authorization: Bearer $TOKEN" \
  "http://localhost:4567/api/v2/products?category=electronics&sort_by=price"

# Filter products using advanced query builder
curl -H "Authorization: Bearer $TOKEN" \
  "http://localhost:4567/api/v2/products/filter?price=gte:50&category=eq:electronics"

# Search for "keyboard"
curl -H "Authorization: Bearer $TOKEN" \
  "http://localhost:4567/api/v2/search?q=keyboard"

# Create a product
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"Mouse Pad","price":19.99,"category":"electronics"}' \
  http://localhost:4567/api/v2/products
```

## Stopping the Application

```bash
docker compose down
```

Add `-v` to also remove the database volume:

```bash
docker compose down -v
```
