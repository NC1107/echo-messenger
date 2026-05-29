#!/usr/bin/env python3
"""
canvas_demo.py — draw a cool design on a voice-lounge canvas, place an avatar,
and a screen-share window, so you can validate on other devices that the canvas
syncs correctly.

It speaks the real Echo wire protocol:
  1. POST /api/auth/login                              -> access token
  2. resolve a group + its voice channel
  3. POST /api/groups/{g}/channels/{c}/voice/join      -> canvas writes accepted
  4. POST /api/auth/ws-ticket                          -> 30s single-use WS ticket
  5. WS  /ws?ticket=...   and send {type:"canvas_event", ...} frames

Canvas events used:
  - "stroke"          {id, color, width, points:[{x,y}], kind:"pen"}   (PERSISTED)
  - "avatar_move"     {user_id, x, y, scale}                           (ephemeral)
  - "screenshare_move"{window_id, x, y, width, height}                 (ephemeral)

Coordinate space is the shared 0..100000 canvas (server accepts -1000..110000).

------------------------------------------------------------------------------
Install:   pip install requests websockets
Run:       python3 scripts/canvas_demo.py --username YOU --password 'PASS'
           # draws in your first group (or pass --group "Name"/<uuid>),
           # or creates one with --create, and loops live until Ctrl+C.

  --once       draw the persisted strokes and exit (good for "join later and
               see it"; avatar/screen-share are ephemeral so only show live).
  --invite     print a group invite link so a SECOND account can join and see
               the LIVE avatar / screen-share (see the note below).

NOTE on what shows where:
  * Strokes are PERSISTED server-side, so ANY group member sees them when they
    open the lounge canvas — even after this script exits, even on the same
    account on another device.
  * avatar_move / screenshare_move are EPHEMERAL (broadcast, not stored) AND the
    server excludes the SENDER's own user-id from canvas broadcasts. So to see
    the live avatar + screen-share window you should join with a DIFFERENT
    account than the one running this script (use --invite). Same-account other
    devices will still see the drawing (persisted) but not the live avatar.
  * Real screen-share *video* comes from LiveKit, not the canvas. This script
    only places the screen-share *window* (the position-sync path). To see an
    actual shared screen, share from a real device.
------------------------------------------------------------------------------
"""
import argparse
import asyncio
import json
import math
import os
import sys
import time
import uuid

try:
    import requests
    import websockets
except ImportError:
    sys.exit("Missing deps. Run:  pip install requests websockets")

CANVAS_CENTER = 3000.0  # centre of the bounded 6000×6000 beta board


# --------------------------------------------------------------------------- #
# Drawing — generate a few rich strokes (each stroke is ONE canvas event, so we
# stay well under the server's ~3 events/sec WS rate limit).
# --------------------------------------------------------------------------- #
# Each canvas event must fit the server's 16 KB per-frame cap, so keep the
# point count modest (~300 ints ≈ 8 KB). Coords are rounded to ints to save
# bytes; the canvas accepts any finite value in -1000..110000.
_MAX_PTS = 300


def _rose(k, radius, n=_MAX_PTS, phase=0.0):
    """A rose / rhodonea curve r = radius * cos(k*theta), centered on canvas."""
    pts = []
    for i in range(n + 1):
        t = (i / n) * 2 * math.pi
        r = radius * math.cos(k * t + phase)
        x = CANVAS_CENTER + r * math.cos(t)
        y = CANVAS_CENTER + r * math.sin(t)
        pts.append({"x": round(x), "y": round(y)})
    return pts


def _circle(radius, n=_MAX_PTS):
    pts = []
    for i in range(n + 1):
        t = (i / n) * 2 * math.pi
        pts.append({
            "x": round(CANVAS_CENTER + radius * math.cos(t)),
            "y": round(CANVAS_CENTER + radius * math.sin(t)),
        })
    return pts


def build_strokes():
    """Returns a list of stroke payloads forming a layered spirograph flower."""
    def stroke(color, width, points, kind="pen", text=None):
        p = {
            "id": f"demo_{uuid.uuid4().hex[:12]}",
            "color": color,
            "width": width,
            "points": points,
            "kind": kind,
        }
        if text is not None:
            p["text"] = text
        return p

    strokes = [
        stroke("#3DDC97", 14.0, _circle(2500)),            # outer ring (Echo green)
        stroke("#FF3DAE", 9.0, _rose(5, 2000)),            # magenta 10-petal rose
        stroke("#38E1FF", 7.0, _rose(4, 1500, phase=0.4)), # cyan rose
        stroke("#FFD93B", 5.0, _rose(7, 1000)),            # gold rose
        stroke("#B388FF", 4.0, _rose(2, 550)),             # violet inner loop
        # A text label (kind="text": single anchor point + text field).
        stroke("#FFFFFF", 220.0,
               [{"x": CANVAS_CENTER - 1300, "y": CANVAS_CENTER + 2750}],
               kind="text", text="ECHO canvas demo ✨"),
    ]
    return strokes


# --------------------------------------------------------------------------- #
# REST helpers
# --------------------------------------------------------------------------- #
class Api:
    def __init__(self, base):
        self.base = base.rstrip("/")
        self.token = None
        self.user_id = None
        self.s = requests.Session()

    def _h(self):
        return {"Authorization": f"Bearer {self.token}"} if self.token else {}

    def login(self, username, password):
        r = self.s.post(f"{self.base}/api/auth/login",
                        json={"username": username, "password": password}, timeout=20)
        if r.status_code != 200:
            sys.exit(f"Login failed ({r.status_code}): {r.text}")
        d = r.json()
        self.token = d["access_token"]
        self.user_id = d["user_id"]
        return d

    def list_conversations(self):
        r = self.s.get(f"{self.base}/api/conversations", headers=self._h(), timeout=20)
        r.raise_for_status()
        return r.json()

    def create_group(self, name):
        r = self.s.post(f"{self.base}/api/groups", headers=self._h(),
                        json={"name": name}, timeout=20)
        if r.status_code not in (200, 201):
            sys.exit(f"create_group failed ({r.status_code}): {r.text}")
        return r.json()

    def channels(self, group_id):
        r = self.s.get(f"{self.base}/api/groups/{group_id}/channels",
                       headers=self._h(), timeout=20)
        r.raise_for_status()
        return r.json()

    def join_voice(self, group_id, channel_id):
        r = self.s.post(
            f"{self.base}/api/groups/{group_id}/channels/{channel_id}/voice/join",
            headers=self._h(), json={}, timeout=20)
        if r.status_code not in (200, 201, 204):
            print(f"  ! voice/join returned {r.status_code}: {r.text[:160]}")
        return r

    def create_invite(self, group_id):
        r = self.s.post(f"{self.base}/api/groups/{group_id}/invites",
                        headers=self._h(), json={}, timeout=20)
        if r.status_code not in (200, 201):
            print(f"  ! could not create invite ({r.status_code}): {r.text[:160]}")
            return None
        return r.json()

    def ws_ticket(self, device_id):
        r = self.s.post(f"{self.base}/api/auth/ws-ticket", headers=self._h(),
                        json={"device_id": device_id}, timeout=20)
        r.raise_for_status()
        return r.json()["ticket"]


def _field(obj, *names):
    for n in names:
        if isinstance(obj, dict) and obj.get(n) not in (None, ""):
            return obj[n]
    return None


def resolve_group(api, wanted, create):
    convs = api.list_conversations()
    items = convs if isinstance(convs, list) else convs.get("conversations", convs)
    groups = []
    for c in items:
        cid = _field(c, "id", "conversation_id")
        name = _field(c, "name", "title", "display_name") or ""
        ctype = (_field(c, "type", "conversation_type", "kind") or "").lower()
        is_group = ctype in ("group", "channel") or _field(c, "is_group") is True \
            or _field(c, "member_count") is not None
        groups.append((cid, name, is_group))

    if wanted:
        for cid, name, _ in groups:
            if cid == wanted or name.lower() == wanted.lower():
                return cid, name
        if not create:
            sys.exit(f"No group matching {wanted!r}. Have: "
                     + ", ".join(n for _, n, _ in groups if n) or "(none)")
    # fall back to first group-like conversation
    for cid, name, is_group in groups:
        if is_group and not wanted:
            return cid, name
    if create or wanted:
        name = wanted or f"Canvas Demo {int(time.time())}"
        g = api.create_group(name)
        return _field(g, "id", "conversation_id"), _field(g, "name") or name
    sys.exit("No group found. Re-run with --create or --group <name>.")


def voice_channel(api, group_id):
    chans = api.channels(group_id)
    chans = chans if isinstance(chans, list) else chans.get("channels", chans)
    for c in chans:
        if (_field(c, "kind", "type") or "").lower() == "voice":
            return _field(c, "id", "channel_id"), _field(c, "name") or "lounge"
    sys.exit("Group has no voice channel.")


# --------------------------------------------------------------------------- #
# WebSocket session
# --------------------------------------------------------------------------- #
async def run_ws(ws_url, channel_id, user_id, strokes, once, clear):
    async with websockets.connect(ws_url, max_size=4 * 1024 * 1024,
                                  ping_interval=20, ping_timeout=20) as ws:
        async def send(kind, payload):
            await ws.send(json.dumps({
                "type": "canvas_event",
                "channel_id": channel_id,
                "kind": kind,
                "payload": payload,
            }))
            await asyncio.sleep(0.45)  # stay under the ~3 msg/sec WS rate limit

        async def drain():
            try:
                async for raw in ws:
                    try:
                        m = json.loads(raw)
                    except Exception:
                        continue
                    t = m.get("type")
                    if t == "canvas_event":
                        print(f"  <- peer canvas_event: {m.get('kind')} "
                              f"from {str(m.get('from_user_id'))[:8]}")
                    elif t in ("voice_session_joined", "voice_session_left"):
                        print(f"  <- {t}: {str(m.get('user_id'))[:8]} "
                              "(someone joined/left the lounge)")
            except Exception:
                pass

        drainer = asyncio.create_task(drain())

        if clear:
            await send("clear", {})
            print("  -> cleared the board")

        print("\nDrawing the design (persisted) ...")
        for i, sp in enumerate(strokes, 1):
            await send("stroke", sp)
            print(f"  -> stroke {i}/{len(strokes)}  ({sp['kind']}, "
                  f"{len(sp['points'])} pts, {sp['color']})")

        avatar = {"user_id": user_id, "x": CANVAS_CENTER, "y": CANVAS_CENTER, "scale": 1.6}
        share = {"window_id": "demo-share", "x": CANVAS_CENTER + 1700,
                 "y": CANVAS_CENTER - 1400, "width": 1200.0, "height": 700.0}
        await send("avatar_move", avatar)
        await send("screenshare_move", share)
        print("  -> placed avatar + screen-share window")

        if once:
            print("\n--once: drawing persisted. Disconnecting.")
            drainer.cancel()
            return

        print("\nLive. Re-broadcasting avatar + screen-share every 6s so a "
              "freshly-joined (different) account sees them.\nPress Ctrl+C to stop.\n")
        try:
            while True:
                await asyncio.sleep(6)
                await send("avatar_move", avatar)
                await send("screenshare_move", share)
        except (KeyboardInterrupt, asyncio.CancelledError):
            pass
        finally:
            drainer.cancel()


def main():
    ap = argparse.ArgumentParser(description="Draw a demo on an Echo voice-lounge canvas.")
    ap.add_argument("--server", default=os.environ.get("ECHO_SERVER",
                    "https://us-east.echo-messenger.us"))
    ap.add_argument("--username", default=os.environ.get("ECHO_USER"))
    ap.add_argument("--password", default=os.environ.get("ECHO_PASS"))
    ap.add_argument("--group", help="group name or conversation UUID (default: first group)")
    ap.add_argument("--create", action="store_true", help="create a group if none matches")
    ap.add_argument("--device-id", type=int, default=9001)
    ap.add_argument("--invite", action="store_true",
                    help="print a group invite link for a second account to join")
    ap.add_argument("--once", action="store_true",
                    help="draw persisted strokes and exit (skip the live loop)")
    ap.add_argument("--clear", action="store_true",
                    help="clear the board before drawing")
    args = ap.parse_args()

    if not args.username or not args.password:
        sys.exit("Need --username and --password (or ECHO_USER / ECHO_PASS env).")

    api = Api(args.server)
    print(f"Logging in to {args.server} as {args.username} ...")
    api.login(args.username, args.password)
    print(f"  ok, user_id={api.user_id[:8]}…")

    group_id, group_name = resolve_group(api, args.group, args.create)
    chan_id, chan_name = voice_channel(api, group_id)
    print(f"Group: {group_name!r} ({group_id})")
    print(f"Voice channel: {chan_name!r} ({chan_id})")

    api.join_voice(group_id, chan_id)
    print("  joined voice channel (canvas writes now accepted)")

    if args.invite:
        inv = api.create_invite(group_id)
        if inv:
            print(f"\n  INVITE (join with a SECOND account to see live avatar/share):")
            print(f"    {inv.get('url')}\n")

    ticket = api.ws_ticket(args.device_id)
    ws_url = args.server.replace("https://", "wss://").replace("http://", "ws://")
    ws_url = f"{ws_url.rstrip('/')}/ws?ticket={ticket}"

    print("\n=== HOW TO VALIDATE ===")
    print(f"  1. Open Echo on your other device(s).")
    print(f"  2. Open the group {group_name!r} → join the '{chan_name}' voice channel.")
    print(f"  3. Switch to Canvas view. You should see the flower design.")
    print(f"     (Persisted strokes show for any member; live avatar/screen-share")
    print(f"      need a DIFFERENT account — see --invite.)")
    print("=======================")

    strokes = build_strokes()
    try:
        asyncio.run(run_ws(ws_url, chan_id, api.user_id, strokes, args.once, args.clear))
    except KeyboardInterrupt:
        pass
    print("Done.")


if __name__ == "__main__":
    main()
