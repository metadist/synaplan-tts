# Synaplan TTS — deploy assets

Production helpers for running Synaplan TTS from the published image and keeping
it up to date automatically. Everything here is meant to live on the server, but
is version-controlled so a fresh host can be brought online — and the auto-update
watchguard reinstalled — deterministically.

## Files

| File | On the server | Purpose |
|---|---|---|
| `../docker-compose.prod.yml` | `<COMPOSE_DIR>/docker-compose.yml` | Image-only compose (no local build) — pulls `ghcr.io/metadist/synaplan-tts:latest`. |
| `watchguard.sh` | `/usr/local/bin/synaplan-tts-watchguard.sh` | Polls GHCR for `ghcr.io/metadist/synaplan-tts:latest`; if the digest differs from the running container's image, runs `docker compose up -d` to redeploy. |
| `synaplan-tts-watchguard.service` | `/etc/systemd/system/synaplan-tts-watchguard.service` | `oneshot` systemd service that runs the script above. |
| `synaplan-tts-watchguard.timer` | `/etc/systemd/system/synaplan-tts-watchguard.timer` | Fires the service every 2 minutes. |

`COMPOSE_DIR` is the directory that holds the compose file and the `voices/`
folder for extra voices. On the reference GPU host it is `/netroot/synaplan-tts`.

## First-time install (fresh server)

```bash
# 1. Stage the deploy directory (COMPOSE_DIR)
sudo mkdir -p /netroot/synaplan-tts/voices
cd /netroot/synaplan-tts

# 2. Bring in the production compose + env from a checkout of this repo
sudo cp /path/to/synaplan-tts/docker-compose.prod.yml docker-compose.yml
sudo cp /path/to/synaplan-tts/.env.example .env
sudo $EDITOR .env                       # set TTS_BIND_ADDRESS to the LAN IP (never 0.0.0.0)

# 3. Start the service (voices en/de/es/fr/tr are baked into the image)
docker compose up -d
curl "http://$(grep -oP 'TTS_BIND_ADDRESS=\K.*' .env):10200/health"   # voices_loaded >= 5
```

## Install (or reinstall) the watchguard

From a checkout of this repo on the server:

```bash
sudo install -m 0755 deploy/watchguard.sh /usr/local/bin/synaplan-tts-watchguard.sh
sudo install -m 0644 deploy/synaplan-tts-watchguard.service /etc/systemd/system/
sudo install -m 0644 deploy/synaplan-tts-watchguard.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now synaplan-tts-watchguard.timer
```

Verify:

```bash
systemctl list-timers synaplan-tts-watchguard.timer
journalctl -u synaplan-tts-watchguard.service -n 50 --no-pager
```

The first run typically logs `watchguard: up to date (<sha256>...), no action`.
A redeploy logs `watchguard: new image detected` followed by the compose
recreate output and `watchguard: redeploy complete`.

### Host-specific overrides (optional)

If `COMPOSE_DIR` or the tracked image differs from the defaults, drop an
`/etc/default/synaplan-tts-watchguard` file — the script sources it:

```bash
COMPOSE_DIR=/opt/synaplan-tts
COMPOSE_FILE=docker-compose.yml
SERVICE_IMAGE=ghcr.io/metadist/synaplan-tts:latest
CONTAINER=synaplan-piper-tts
```

## How it interacts with the deploy flow

```
git push origin main
  → GitHub Actions CI                             (build + push)
    → ghcr.io/metadist/synaplan-tts:latest        (new digest)
      → synaplan-tts-watchguard.timer fires within 2 min  (polls GHCR)
        → docker pull
          → if digest changed: docker compose up -d        (recreates piper)
```

To force an update immediately:

```bash
sudo systemctl start synaplan-tts-watchguard.service
```

## Extra voices

The published image already ships `en`, `de`, `es`, `fr`, `tr`. To add more,
drop the `<voice>.onnx` and `<voice>.onnx.json` files into `<COMPOSE_DIR>/voices/`
(mounted read-only at `/voices-extra`) and restart:

```bash
docker compose restart piper
```

Do **not** mount `./voices` over `/voices` — that hides the five baked models.

## What this does *not* do

- It does **not** sync `docker-compose.yml` from this repo to the server. Compose
  changes still need a manual copy of `docker-compose.prod.yml`. The watchguard
  only updates the *container image*, not the orchestration manifest.
- It does **not** roll back on healthcheck failure. If a bad build ships, the
  next watchguard run pulls the next-pushed image; for an emergency pin, edit
  `docker-compose.yml` on the server and set an explicit tag (e.g. `:vX.Y.Z`
  instead of `:latest`), then `docker compose up -d`.
- It does **not** do blue/green or zero-downtime upgrades. The `piper` container
  is briefly recreated (a few seconds), acceptable for this stateless service.

## Troubleshooting

- **Container stuck on an old image** (the failure mode this script exists to
  fix): check `systemctl status synaplan-tts-watchguard.timer`. If inactive,
  `systemctl enable --now synaplan-tts-watchguard.timer`.
- **Timer fires but image never pulls**: run the script by hand —
  `sudo /usr/local/bin/synaplan-tts-watchguard.sh` — and inspect the output.
  A GHCR rate limit or a broken `docker login` will surface there.
- **No voices after start**: confirm `./voices` is mounted at `/voices-extra`
  (not `/voices`) and that `GET /health` reports `voices_loaded >= 5`.
