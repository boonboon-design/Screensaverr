#!/usr/bin/env python3
"""Fake Sonarr / Radarr / Seerr / SABnzbd for CI screenshots.

Serves everything from one port under URL bases (/sonarr, /radarr, /seerr, /sab), which also
exercises URL-base handling. Dates are relative to "now". API key: "testkey".
"""
import datetime as dt
import hashlib
import json
import random
import struct
import sys
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18989
KEY = "testkey"
START = time.monotonic()
BASE = f"http://127.0.0.1:{PORT}"
NOW = dt.datetime.now(dt.timezone.utc)


def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


def day(offset):
    d = (NOW + dt.timedelta(days=offset)).date()
    return f"{d.isoformat()}T00:00:00Z"


def at(days, hour, minute=0):
    d = (NOW + dt.timedelta(days=days)).replace(hour=hour, minute=minute, second=0, microsecond=0)
    return iso(d)


def images(slug, local_id, base):
    return [
        {"coverType": "poster", "url": f"{base}/MediaCover/{local_id}/poster.jpg?lastWrite=1",
         "remoteUrl": f"{BASE}/img/poster-{slug}.png"},
        {"coverType": "fanart", "url": f"{base}/MediaCover/{local_id}/fanart.jpg?lastWrite=1",
         "remoteUrl": f"{BASE}/img/fanart-{slug}.png"},
    ]


SHOWS = [
    # (series id, title, network, slug)
    (1, "The Last Frontier", "Apple TV+", "frontier"),
    (2, "Night Shift", "Netflix", "nightshift"),
    (3, "Harbor Lights", "HBO", "harbor"),
    (4, "Copper Valley", "AMC", "copper"),
    (5, "Orbit", "Hulu", "orbit"),
    (6, "Morning Brew", "CBS", "brew"),
    (7, "Kingsguard", "Prime Video", "kingsguard"),
]


def series(sid):
    s = next(x for x in SHOWS if x[0] == sid)
    return {"id": s[0], "title": s[1], "network": s[2], "images": images(s[3], s[0], "/sonarr")}


def episode(eid, sid, season, number, title, when, has_file=False, finale=None):
    e = {"id": eid, "seriesId": sid, "seasonNumber": season, "episodeNumber": number, "title": title,
         "airDateUtc": when, "airDate": when[:10], "hasFile": has_file, "monitored": True,
         "series": series(sid)}
    if finale:
        e["finaleType"] = finale
    return e


def sonarr_calendar():
    eps = [
        episode(1, 6, 11, 40, "Fall Preview", iso(NOW - dt.timedelta(hours=1)), has_file=True),
        episode(2, 1, 2, 5, "Into the Storm", iso(NOW + dt.timedelta(hours=3))),
    ]
    for n in range(1, 9):
        eps.append(episode(10 + n, 2, 1, n, "Pilot" if n == 1 else f"Shift {n}", at(1, 7)))
    eps += [
        episode(30, 3, 3, 2, "The Keeper", at(1, 21)),
        episode(31, 4, 1, 6, "Rust", at(2, 2)),
        episode(32, 5, 4, 10, "Perigee", at(3, 1), finale="season"),
        episode(33, 7, 2, 1, "A New Oath", at(5, 20)),
    ]
    return eps


def movie(mid, title, year, genres, runtime, slug, **dates):
    m = {"id": mid, "tmdbId": 1000 + mid, "title": title, "year": year, "genres": genres, "runtime": runtime,
         "studio": "Studio", "hasFile": dates.pop("has_file", False), "monitored": True,
         "images": images(slug, mid, "/radarr")}
    m.update(dates)
    return m


def radarr_calendar():
    return [
        movie(1, "Paper Moons", 2026, ["Drama", "Romance"], 118, "papermoons",
              inCinemas=day(-40), digitalRelease=day(0), has_file=True),
        movie(2, "The Glass Garden", 2026, ["Fantasy", "Adventure"], 131, "glassgarden", inCinemas=day(3)),
        movie(3, "Signal Lost", 2026, ["Thriller"], 102, "signallost", inCinemas=day(-30), digitalRelease=day(9)),
        movie(4, "Northern Drift", 2026, ["Documentary"], 94, "northern", physicalRelease=day(16)),
        movie(5, "Ember & Ash", 2026, ["Action", "Science Fiction"], 149, "ember", inCinemas=day(30)),
        movie(6, "Tidewater", 2026, ["Mystery"], 110, "tidewater", inCinemas=day(-20), digitalRelease=day(45)),
    ]


REQUESTS = [
    # id, type, tmdb, request status, media status, user, hours ago, seasons, 4k
    (101, "movie", 501, 1, 2, "Alice", 0.5, None, False),
    (102, "tv", 502, 2, 3, "bob", 3, [1, 2], False),
    (103, "movie", 503, 2, 5, "Carol", 20, None, False),
    (104, "tv", 504, 2, 4, "Dan", 30, [3], False),
    (105, "movie", 505, 3, 1, "Erin", 50, None, False),
    (106, "movie", 506, 2, 3, "Alice", 70, None, True),
]

DETAILS = {
    501: {"title": "Moonlit Avenue", "releaseDate": "2026-11-20"},
    502: {"name": "Glass Houses", "firstAirDate": "2024-03-02"},
    503: {"title": "The Long Way North", "releaseDate": "2026-06-12"},
    504: {"name": "Saltwater", "firstAirDate": "2022-09-15"},
    505: {"title": "Static Bloom", "releaseDate": "2025-02-14"},
    506: {"title": "Atlas Rising", "releaseDate": "2026-08-01"},
}


def seerr_requests():
    results = []
    for rid, kind, tmdb, status, mstatus, user, hours, seasons, uhd in REQUESTS:
        r = {"id": rid, "status": status, "type": kind, "is4k": uhd,
             "createdAt": iso(NOW - dt.timedelta(hours=hours)).replace("Z", ".000Z"),
             "media": {"tmdbId": tmdb, "mediaType": kind, "status": 5 if uhd else mstatus,
                       "status4k": mstatus if uhd else 1},
             "requestedBy": {"displayName": user}}
        if seasons:
            r["seasons"] = [{"seasonNumber": s} for s in seasons]
        results.append(r)
    return {"pageInfo": {"pages": 1, "pageSize": 10, "results": len(results), "page": 1}, "results": results}


RECENT = [
    # tmdb, type, title, year, hours ago
    (601, "movie", "Lanterns", 2026, 2),
    (602, "tv", "The Quiet Coast", 2025, 5),
    (603, "movie", "Second Sunrise", 2026, 9),
    (604, "movie", "Ironwood", 2024, 20),
    (605, "tv", "Hollow Pines", 2026, 30),
    (606, "movie", "Paper Moons", 2026, 44),
    (607, "movie", "North by Night", 2023, 60),
    (608, "tv", "Saltwater", 2022, 80),
    (609, "movie", "Glasswing", 2026, 96),
]
for tmdb, kind, title, year, _ in RECENT:
    DETAILS[tmdb] = {"title" if kind == "movie" else "name": title,
                     "releaseDate" if kind == "movie" else "firstAirDate": f"{year}-05-01"}


def seerr_media():
    results = [{"id": i, "tmdbId": tmdb, "mediaType": kind, "status": 5,
                "mediaAddedAt": iso(NOW - dt.timedelta(hours=hours)).replace("Z", ".000Z")}
               for i, (tmdb, kind, _, _, hours) in enumerate(RECENT, start=1)]
    return {"pageInfo": {"pages": 1, "pageSize": 20, "results": len(results), "page": 1}, "results": results}


def tautulli_activity():
    sessions = [
        {"session_key": "41", "media_type": "episode", "grandparent_title": "Harbor Lights", "title": "The Keeper",
         "parent_media_index": "3", "media_index": "2", "friendly_name": "Alice", "user": "alice",
         "state": "playing", "progress_percent": "37", "transcode_decision": "direct play",
         "stream_video_full_resolution": "4k", "player": "Living Room",
         "grandparent_thumb": "/library/metadata/100/thumb/1"},
        {"session_key": "42", "media_type": "movie", "title": "Paper Moons", "year": "2026",
         "friendly_name": "bob", "state": "paused", "progress_percent": "81", "transcode_decision": "transcode",
         "stream_video_full_resolution": "1080p", "player": "iPad", "thumb": "/library/metadata/200/thumb/1"},
        {"session_key": "43", "media_type": "episode", "grandparent_title": "Orbit", "title": "Perigee",
         "parent_media_index": "4", "media_index": "10", "friendly_name": "Carol", "state": "playing",
         "progress_percent": "12", "transcode_decision": "copy", "stream_video_full_resolution": "1080p",
         "grandparent_thumb": "/library/metadata/300/thumb/1"},
    ]
    return {"stream_count": str(len(sessions)), "stream_count_direct_play": 1, "stream_count_direct_stream": 1,
            "stream_count_transcode": 1, "total_bandwidth": 48000, "sessions": sessions}


def seerr_details(kind, tmdb):
    d = dict(DETAILS.get(tmdb, {"title": f"Item {tmdb}"}))
    d["id"] = tmdb
    d["posterPath"] = f"/does-not-exist-{tmdb}.jpg"
    return d


def sab_queue():
    speed = random.uniform(36000, 52000)  # KB/s
    slots = [
        ("Night.Shift.S01E08.1080p.WEB.h264-GRP", "Downloading", "tv", 2400, 864),
        ("The.Glass.Garden.2026.2160p.UHD.BluRay.x265-GRP", "Queued", "movies", 58000, 58000),
        ("Harbor.Lights.S03E01.1080p.WEB.h264-GRP", "Queued", "tv", 3100, 3100),
        ("Orbit.S04E09.720p.WEB.h264-GRP", "Paused", "tv", 1400, 1400),
        ("Signal.Lost.2026.1080p.WEB-DL.DDP5.1-GRP", "Queued", "movies", 7200, 7200),
    ]
    total = sum(s[3] for s in slots)
    left = sum(s[4] for s in slots)
    out = []
    for i, (name, status, cat, mb, mbleft) in enumerate(slots):
        out.append({"index": i, "nzo_id": f"SABnzbd_nzo_{i}", "filename": name, "status": status, "cat": cat,
                    "percentage": str(int((mb - mbleft) / mb * 100)), "mb": f"{mb:.2f}", "mbleft": f"{mbleft:.2f}",
                    "timeleft": "0:00:20" if i == 0 else "0:00:00"})
    secs = int(left * 1024 / speed)
    return {"queue": {"status": "Downloading", "paused": False, "kbpersec": f"{speed:.2f}", "speed": "42.3 M",
                      "mb": f"{total:.2f}", "mbleft": f"{left:.2f}", "timeleft": f"{secs // 3600}:{secs % 3600 // 60:02d}:{secs % 60:02d}",
                      "noofslots": len(out), "noofslots_total": len(out), "slots": out}}


def sab_history():
    ts = int(NOW.timestamp())
    return {"history": {"day_size": "34.2 G", "week_size": "120.0 G", "slots": [
        {"nzo_id": "h1", "name": "Morning.Brew.S11E40.1080p.WEB", "status": "Completed", "completed": ts - 1800, "bytes": 1.2e9},
        {"nzo_id": "h2", "name": "Paper.Moons.2026.1080p.WEB-DL", "status": "Completed", "completed": ts - 7200, "bytes": 6.4e9},
        {"nzo_id": "h3", "name": "Broken.Release.720p", "status": "Failed", "completed": ts - 9000, "bytes": 0},
    ]}}


# --- tiny PNG generator (no Pillow needed) ---------------------------------------------

def png(width, height, seed, poster):
    rnd = random.Random(seed)
    c1 = [rnd.randint(40, 200) for _ in range(3)]
    c2 = [rnd.randint(10, 90) for _ in range(3)]
    cx, cy, r = rnd.uniform(0.3, 0.7), rnd.uniform(0.25, 0.6), rnd.uniform(0.15, 0.3)
    rows = []
    for y in range(height):
        t = y / height
        row = bytearray([0])
        for x in range(width):
            u = x / width
            col = [int(c1[i] * (1 - t) + c2[i] * t) for i in range(3)]
            dx, dy = (u - cx) * (width / height if not poster else 1), (t - cy) * (1 if not poster else height / width)
            if dx * dx + dy * dy < r * r:
                col = [min(255, int(v * 1.5 + 30)) for v in col]
            if poster and t > 0.78:
                col = [int(v * 0.55) for v in col]
            row.extend(col)
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


IMAGE_CACHE = {}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stdout.write("mock %7.3f: %s\n" % (time.monotonic() - START, fmt % args))
        sys.stdout.flush()

    def send_json(self, obj, status=200, chunked=False):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for i in range(0, len(body), 700):
                part = body[i:i + 700]
                self.wfile.write(f"{len(part):X}\r\n".encode() + part + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
        else:
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def send_image(self, name):
        if name not in IMAGE_CACHE:
            poster = name.startswith("poster")
            w, h = (300, 450) if poster else (960, 540)
            IMAGE_CACHE[name] = png(w, h, hashlib.md5(name.encode()).hexdigest(), poster)
        body = IMAGE_CACHE[name]
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authed(self):
        return self.headers.get("X-Api-Key") == KEY

    def do_GET(self):
        url = urlparse(self.path)
        path, query = url.path, parse_qs(url.query)

        if path.startswith("/img/"):
            return self.send_image(path[len("/img/"):])

        for app in ("sonarr", "radarr"):
            prefix = f"/{app}/api/v3/"
            if path.startswith(prefix):
                if not self.authed():
                    return self.send_json({"error": "Unauthorized"}, 401)
                endpoint = path[len(prefix):]
                if endpoint == "system/status":
                    return self.send_json({"appName": app.capitalize(), "version": "4.0.15.2941"})
                if endpoint == "calendar":
                    data = sonarr_calendar() if app == "sonarr" else radarr_calendar()
                    return self.send_json(data, chunked=(app == "sonarr"))
                return self.send_json({"error": "not found"}, 404)

        if path.startswith("/seerr/api/v1/"):
            endpoint = path[len("/seerr/api/v1/"):]
            if endpoint == "status":
                return self.send_json({"version": "2.7.3", "commitTag": "local"})
            if not self.authed():
                return self.send_json({"message": "Unauthorized"}, 403)
            if endpoint == "request/count":
                return self.send_json({"total": 42, "movie": 30, "tv": 12, "pending": 1, "approved": 3,
                                       "declined": 1, "processing": 3, "available": 30, "completed": 8})
            if endpoint == "request":
                return self.send_json(seerr_requests())
            if endpoint == "media":
                return self.send_json(seerr_media())
            parts = endpoint.split("/")
            if len(parts) == 2 and parts[0] in ("movie", "tv"):
                return self.send_json(seerr_details(parts[0], int(parts[1])))
            return self.send_json({"message": "not found"}, 404)

        if path == "/sab/api":
            mode = query.get("mode", [""])[0]
            if mode == "version":
                return self.send_json({"version": "4.5.1"})
            if query.get("apikey", [""])[0] != KEY:
                return self.send_json({"status": False, "error": "API Key Incorrect"})
            if mode == "queue":
                return self.send_json(sab_queue())
            if mode == "history":
                return self.send_json(sab_history())
            return self.send_json({"status": False, "error": "not implemented"})

        if path == "/tautulli/api/v2":
            cmd = query.get("cmd", [""])[0]
            if query.get("apikey", [""])[0] != KEY:
                return self.send_json({"response": {"result": "error", "message": "Invalid apikey", "data": {}}}, 401)
            if cmd == "pms_image_proxy":
                return self.send_image("poster-" + query.get("img", ["x"])[0].replace("/", "-") + ".png")
            if cmd == "get_tautulli_info":
                data = {"tautulli_version": "v2.15.3"}
            elif cmd == "get_activity":
                data = tautulli_activity()
            else:
                return self.send_json({"response": {"result": "error", "message": "Unknown command", "data": {}}}, 400)
            return self.send_json({"response": {"result": "success", "message": None, "data": data}})

        self.send_json({"error": "not found"}, 404)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"mock server on {BASE}", flush=True)
    server.serve_forever()
