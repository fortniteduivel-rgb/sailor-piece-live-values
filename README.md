# Sailor Piece Live Value Table

This project serves a live Sailor Piece value table with:

- `Web Value` from the public Sailor Piece value API
- `Live Trade Value` from recent direct CRR trade ads
- automatic refresh for both the table and the trade-based averages

## Local Run

Start the local server:

```sh
./serve.sh
```

Then open:

```text
http://127.0.0.1:4173/
```

Use a different port if needed:

```sh
./serve.sh 8080
```

## Render Deploy

This repo is prepped for Render using Docker.

Files added for deploy:

- `Dockerfile`
- `render.yaml`
- `server.rb` with `PORT`, `BIND_ADDRESS`, and `/health`

### Steps

1. Create a GitHub repo and push this project.
2. In Render, choose `New +` -> `Blueprint`.
3. Select your repo.
4. Render will detect `render.yaml` and create the web service.
5. Deploy it.
6. Open the generated `onrender.com` URL.

### Notes

- The app must be deployed as a web service, not a static site, because `/api/live-trade-averages` is generated server-side.
- The server binds to `0.0.0.0` on Render automatically.
- Health checks use:

```text
/health
```

## Main Files

- `index.html`: root public page
- `sailor-piece-live-value-table-discord.html`: standalone table page
- `server.rb`: local/API server
- `serve.sh`: local launcher
