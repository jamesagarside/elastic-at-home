#!/usr/bin/env python3
"""
Elastic at Home - Architecture diagram generator.

Hand-curated SVG. No auto-layout - every coordinate is chosen.
Replaces the previous Structurizr Lite + Puppeteer pipeline with stdlib-only
Python that emits a single SVG, with icons inlined as data URIs.

Usage:
    python3 scripts/render-architecture.py > images/architecture/architecture.svg
    rsvg-convert -w 1800 images/architecture/architecture.svg \\
        -o images/architecture/architecture.png
"""
from __future__ import annotations

import base64
import pathlib
import re
import xml.sax.saxutils as xml

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
ICONS = ROOT / "images" / "icons"

# ---------------------------------------------------------------------------
# Design tokens
# ---------------------------------------------------------------------------
PALETTE = {
    "primary": "#0B64DD",
    "teal":    "#008B87",
    "pink":    "#BC1E70",
    "amber":   "#E07A1F",       # darker amber -- readable on white
    "text":    "#111C2C",
    "muted":   "#516381",
    "hairline":"#DCE3EF",
    "card":    "#FFFFFF",
    "zoneExt": "#F3F6FB",
    "zoneDock":"#EEF4FD",
    "zoneNet": "#FBF4EC",
    "dockerStroke":"#B7CDEA",
    "netStroke": "#E4CBA8",
    "bg":      "#F8FAFC",
    "accentBg":"#F0F5FF",
}

W, H = 1680, 1020

# Label offset above their flow line (consistent across all badges)
LABEL_OFFSET = 16

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def b64_png(path: pathlib.Path) -> str:
    return "data:image/png;base64," + base64.b64encode(path.read_bytes()).decode()

def read_svg_inner(path: pathlib.Path, new_fill: str | None = None) -> str:
    s = path.read_text()
    s = re.sub(r"<\?xml[^>]*\?>", "", s).strip()
    inner = re.sub(r"<svg[^>]*>", "", s)
    inner = inner.replace("</svg>", "").strip()
    inner = re.sub(r"<title>.*?</title>", "", inner, flags=re.DOTALL)
    if new_fill is not None:
        inner = re.sub(r'fill="[^"]*"', f'fill="{new_fill}"', inner)
        if 'fill=' not in inner:
            inner = inner.replace("<path", f'<path fill="{new_fill}"', 1)
    return inner

def esc(s: str) -> str:
    return xml.escape(s)

# ---------------------------------------------------------------------------
# Node positions  (hand-curated; 8px grid)
# ---------------------------------------------------------------------------
# External zone
P_USER    = (218,  260)
P_NET     = (218,  480)
P_REMOTE  = (218,  700)

# Traefik (gateway pivot) - pulled left so services column breathes
P_TRAEFIK = (520,  480)

# Services column
P_KIBANA  = (900,  260)
P_FLEET   = (900,  480)
P_AGENT   = (900,  700)

# Elasticsearch (terminus - larger, further right)
P_ES      = (1380, 480)

# Cloud / Internet zone (external SaaS -- Cloudflare lives OFF the Docker
# host). Positioned in the right half of the Internet zone so the zone title
# "INTERNET" has room to breathe on the left. Centre y is pulled down slightly
# below the zone's centre so the card sits comfortably under the zone title
# block while still keeping the ACME line above Kibana's top edge (y=206).
P_CF      = (1500, 185)

EXT_ZONE    = (88,   120, 260, 740)
# Docker zone has a cut-out in its upper-right corner so the Internet zone can
# sit flush in the top-right without overlap. The zone is emitted as a path,
# not a rect, with the notch sized to match INTERNET_ZONE.
DOCKER_ZONE = (388,  120, 1204, 740)
INTERNET_ZONE = (1260, 120, 332, 160)  # top-right, flush against Docker cut-out

NODE_W, NODE_H = 168, 108

# ---------------------------------------------------------------------------
# SVG primitives
# ---------------------------------------------------------------------------
def node(x, y, label, caption, icon_kind=None, icon_data=None, w=NODE_W, h=NODE_H,
         icon_size=46, emphasis=False, accent_color=None):
    """
    Card node.
    icon_kind: 'svg' (raw inner markup) or 'png' (data URI) or None.
    """
    nx, ny = x - w/2, y - h/2
    stroke = PALETTE["hairline"]
    stroke_w = 1.1
    if emphasis:
        stroke = accent_color or PALETTE["primary"]
        stroke_w = 1.75

    icon_block = ""
    if icon_kind == "svg" and icon_data is not None:
        ix = x - icon_size/2
        iy = ny + 18
        icon_block = (
            f'<g transform="translate({ix},{iy}) scale({icon_size/24:.5f})">{icon_data}</g>'
        )
    elif icon_kind == "png" and icon_data is not None:
        ix = x - icon_size/2
        iy = ny + 18
        icon_block = (
            f'<image x="{ix}" y="{iy}" width="{icon_size}" height="{icon_size}" '
            f'href="{icon_data}" preserveAspectRatio="xMidYMid meet"/>'
        )

    label_y = ny + h - 30
    caption_y = ny + h - 13

    accent_bar = ""
    if emphasis:
        accent_bar = (f'<rect x="{nx + 12}" y="{ny + h - 5}" width="{w - 24}" '
                      f'height="2" rx="1" fill="{accent_color or PALETTE["primary"]}"/>')

    return f"""
<g class="node">
  <rect x="{nx}" y="{ny}" width="{w}" height="{h}" rx="12" ry="12"
        fill="{PALETTE['card']}" stroke="{stroke}" stroke-width="{stroke_w}"
        filter="url(#cardshadow)"/>
  {accent_bar}
  {icon_block}
  <text x="{x}" y="{label_y}" text-anchor="middle"
        font-family="Inter,Helvetica Neue,Arial,sans-serif"
        font-size="15" font-weight="600" fill="{PALETTE['text']}"
        letter-spacing="-0.15">{esc(label)}</text>
  <text x="{x}" y="{caption_y}" text-anchor="middle"
        font-family="Inter,Helvetica Neue,Arial,sans-serif"
        font-size="10.5" font-weight="500" fill="{PALETTE['muted']}"
        letter-spacing="0.15">{esc(caption)}</text>
</g>"""

def es_node(x, y):
    """Elasticsearch -- larger card (terminus of data flows) but styled identically to every other node."""
    w, h = 260, 190
    nx, ny = x - w/2, y - h/2
    icon_png = b64_png(ICONS / "elasticsearch.png")
    icon_size = 72
    ix = x - icon_size/2
    iy = ny + 28

    return f"""
<g class="node node-es">
  <rect x="{nx}" y="{ny}" width="{w}" height="{h}" rx="14" ry="14"
        fill="{PALETTE['card']}" stroke="{PALETTE['hairline']}" stroke-width="1.1"
        filter="url(#cardshadow)"/>
  <image x="{ix}" y="{iy}" width="{icon_size}" height="{icon_size}"
         href="{icon_png}" preserveAspectRatio="xMidYMid meet"/>
  <text x="{x}" y="{ny + h - 54}" text-anchor="middle"
        font-family="Inter,Helvetica Neue,Arial,sans-serif"
        font-size="19" font-weight="700" fill="{PALETTE['text']}"
        letter-spacing="-0.3">Elasticsearch</text>
  <text x="{x}" y="{ny + h - 33}" text-anchor="middle"
        font-family="Inter,Helvetica Neue,Arial,sans-serif"
        font-size="11" font-weight="600" fill="{PALETTE['muted']}"
        letter-spacing="1.6">SEARCH · ANALYTICS · STORAGE</text>
  <text x="{x}" y="{ny + h - 14}" text-anchor="middle"
        font-family="JetBrains Mono,SF Mono,Menlo,monospace"
        font-size="11" font-weight="600" fill="{PALETTE['primary']}"
        letter-spacing="0.2">:9200</text>
</g>"""

def zone(x, y, w, h, title, subtitle, dashed=False, stroke=None, fill=None,
         path=None):
    stroke = stroke or PALETTE["muted"]
    fill = fill or PALETTE["zoneExt"]
    dash = 'stroke-dasharray="4 6"' if dashed else ""
    if path is not None:
        shape = (f'<path d="{path}" fill="{fill}" stroke="{stroke}" '
                 f'stroke-width="1.2" stroke-linejoin="round" {dash}/>')
    else:
        shape = (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="16" ry="16" '
                 f'fill="{fill}" stroke="{stroke}" stroke-width="1.2" {dash}/>')
    return f"""
<g class="zone">
  {shape}
  <text x="{x + 24}" y="{y + 34}"
        font-family="Inter,Helvetica Neue,Arial,sans-serif"
        font-size="10.5" font-weight="700"
        fill="{PALETTE['muted']}" letter-spacing="2.6">{esc(title.upper())}</text>
  <text x="{x + 24}" y="{y + 54}"
        font-family="Inter,Helvetica Neue,Arial,sans-serif"
        font-size="12" font-weight="500" fill="{PALETTE['text']}"
        letter-spacing="-0.1">{esc(subtitle)}</text>
</g>"""

# ---------------------------------------------------------------------------
# Edge routing: ORTHOGONAL ONLY.
# Every edge in the diagram uses horizontal + vertical segments joined by
# 90-degree turns with a single, fixed corner radius (CORNER_R).
# Arrow tips land perpendicular to the target node edge.
# ---------------------------------------------------------------------------
CORNER_R = 8  # uniform corner radius for every bend, every edge


def ortho_path(points, color, width=2.4, dashed=False, arrow=True, opacity=1.0):
    """
    Draw a Manhattan polyline through the given waypoints.

    Each waypoint pair must differ in exactly one axis (pure horizontal or
    pure vertical segment) -- the caller is responsible for emitting a clean
    lane plan. Corners are rounded with a fixed radius using a quadratic
    curve so every bend in the diagram looks identical.
    """
    if len(points) < 2:
        return ""

    # Normalise: collapse any degenerate (zero-length) segments so the corner
    # logic doesn't trip over repeated waypoints.
    pts = [points[0]]
    for p in points[1:]:
        if p != pts[-1]:
            pts.append(p)
    if len(pts) < 2:
        return ""

    def seg_len(a, b):
        return abs(a[0] - b[0]) + abs(a[1] - b[1])  # manhattan; one axis is 0

    d = [f"M{pts[0][0]:.1f},{pts[0][1]:.1f}"]
    for i in range(1, len(pts)):
        p_prev = pts[i - 1]
        p_curr = pts[i]
        if i == len(pts) - 1:
            # Last segment: draw straight to endpoint.
            d.append(f"L{p_curr[0]:.1f},{p_curr[1]:.1f}")
            continue
        p_next = pts[i + 1]
        # radius clipped so it never exceeds half of either adjacent segment
        r = min(CORNER_R, seg_len(p_prev, p_curr) / 2, seg_len(p_curr, p_next) / 2)
        # Direction from prev -> curr
        dx1 = 0 if p_curr[0] == p_prev[0] else (1 if p_curr[0] > p_prev[0] else -1)
        dy1 = 0 if p_curr[1] == p_prev[1] else (1 if p_curr[1] > p_prev[1] else -1)
        # Direction from curr -> next
        dx2 = 0 if p_next[0] == p_curr[0] else (1 if p_next[0] > p_curr[0] else -1)
        dy2 = 0 if p_next[1] == p_curr[1] else (1 if p_next[1] > p_curr[1] else -1)
        # Approach point (r before the corner, along prev->curr)
        ax = p_curr[0] - dx1 * r
        ay = p_curr[1] - dy1 * r
        # Leave point (r after the corner, along curr->next)
        bx = p_curr[0] + dx2 * r
        by = p_curr[1] + dy2 * r
        d.append(f"L{ax:.1f},{ay:.1f}")
        # Quadratic with the corner as its control point gives a clean,
        # identical-looking fillet at every turn.
        d.append(f"Q{p_curr[0]:.1f},{p_curr[1]:.1f} {bx:.1f},{by:.1f}")

    dash = 'stroke-dasharray="7 6"' if dashed else ""
    marker = f'marker-end="url(#arrow-{color.lstrip("#")})"' if arrow else ""
    return (f'<path d="{" ".join(d)}" fill="none" stroke="{color}" '
            f'stroke-width="{width}" stroke-linecap="round" '
            f'stroke-linejoin="round" opacity="{opacity}" {dash} {marker}/>')


# Back-compat alias: the rest of the file still calls path_via(...) -- every
# one of those call sites has been migrated to supply orthogonal waypoints.
path_via = ortho_path

def badge(x, y, text, color, size="sm"):
    if size == "lg":
        fs, padx, pady = 11, 14, 7
    else:
        fs, padx, pady = 10, 11, 5
    w = max(50, fs * 0.62 * len(text) + 2 * padx)
    h = fs + 2 * pady
    nx, ny = x - w/2, y - h/2
    return f"""
<g class="badge">
  <rect x="{nx}" y="{ny}" width="{w}" height="{h}" rx="{h/2}"
        fill="#FFFFFF" stroke="{color}" stroke-width="1.1"/>
  <text x="{x}" y="{y + fs*0.35}" text-anchor="middle"
        font-family="JetBrains Mono,SF Mono,Menlo,monospace"
        font-size="{fs}" font-weight="600" fill="{color}">{esc(text)}</text>
</g>"""

# ---------------------------------------------------------------------------
# Compose
# ---------------------------------------------------------------------------
def build_svg() -> str:
    icon_es      = b64_png(ICONS / "elasticsearch.png")
    icon_kb      = b64_png(ICONS / "kibana.png")
    icon_agent   = b64_png(ICONS / "agent.png")
    icon_elastic = b64_png(ICONS / "elastic.png")

    traefik_inner    = read_svg_inner(ICONS / "traefik.svg", "#24A1C1")
    cloudflare_inner = read_svg_inner(ICONS / "cloudflare.svg", "#F38020")
    network_inner    = read_svg_inner(ICONS / "network.svg", PALETTE["muted"])

    # --- defs -------------------------------------------------------------
    arrow_defs = []
    arrow_colors = {
        "0B64DD": PALETTE["primary"],
        "008B87": PALETTE["teal"],
        "BC1E70": PALETTE["pink"],
        "E07A1F": PALETTE["amber"],
        "516381": PALETTE["muted"],
    }
    for name, col in arrow_colors.items():
        # markerUnits="userSpaceOnUse" so arrow size is constant across all
        # strokes (independent of line width). refX=10 places the arrow tip
        # exactly at the path endpoint, so every arrow lands on the node
        # edge rather than floating just inside.
        arrow_defs.append(f"""
    <marker id="arrow-{name}" viewBox="0 0 10 10" refX="10" refY="5"
            markerWidth="11" markerHeight="11"
            markerUnits="userSpaceOnUse" orient="auto-start-reverse">
      <path d="M0,0 L10,5 L0,10 z" fill="{col}"/>
    </marker>""")

    defs = f"""
<defs>
  <filter id="cardshadow" x="-20%" y="-20%" width="140%" height="160%">
    <feDropShadow dx="0" dy="2" stdDeviation="3" flood-color="#0B64DD" flood-opacity="0.09"/>
    <feDropShadow dx="0" dy="1" stdDeviation="0.8" flood-color="#111C2C" flood-opacity="0.06"/>
  </filter>
  <pattern id="dotgrid" width="28" height="28" patternUnits="userSpaceOnUse">
    <circle cx="1" cy="1" r="0.85" fill="#E4EAF2"/>
  </pattern>
  {''.join(arrow_defs)}
</defs>"""

    # --- header ------------------------------------------------------------
    header = f"""
<g class="header">
  <image x="64" y="36" width="40" height="40" href="{icon_elastic}"/>
  <text x="118" y="58"
        font-family="Inter,Helvetica Neue,Arial,sans-serif"
        font-size="22" font-weight="700" fill="{PALETTE['text']}"
        letter-spacing="-0.5">Elastic at Home</text>
  <text x="118" y="78"
        font-family="Inter,Helvetica Neue,Arial,sans-serif"
        font-size="12.5" font-weight="500" fill="{PALETTE['muted']}"
        letter-spacing="-0.05">Self-hosted Elastic Stack for home SIEM, XDR &amp; log aggregation</text>
  <line x1="64" y1="94" x2="{W - 64}" y2="94"
        stroke="{PALETTE['hairline']}" stroke-width="1"/>
</g>"""

    # --- zones -------------------------------------------------------------
    # Docker zone is drawn as a rounded-rect path with a square notch removed
    # from its top-right corner so the Internet zone sits flush against it
    # (shared edge at x=1260 between y=120..250, and at y=250 between
    # x=1260..1592). This avoids zone overlap and keeps every node under
    # exactly one zone.
    dz_x, dz_y, dz_w, dz_h = DOCKER_ZONE
    iz_x, iz_y, iz_w, iz_h = INTERNET_ZONE
    dz_r = 16
    docker_path = (
        f"M {dz_x + dz_r},{dz_y} "
        f"L {iz_x},{dz_y} "
        f"L {iz_x},{iz_y + iz_h} "
        f"L {dz_x + dz_w},{iz_y + iz_h} "
        f"L {dz_x + dz_w},{dz_y + dz_h - dz_r} "
        f"Q {dz_x + dz_w},{dz_y + dz_h} {dz_x + dz_w - dz_r},{dz_y + dz_h} "
        f"L {dz_x + dz_r},{dz_y + dz_h} "
        f"Q {dz_x},{dz_y + dz_h} {dz_x},{dz_y + dz_h - dz_r} "
        f"L {dz_x},{dz_y + dz_r} "
        f"Q {dz_x},{dz_y} {dz_x + dz_r},{dz_y} Z"
    )
    zones = [
        zone(*EXT_ZONE, "External sources", "Beyond the Docker host",
             dashed=True, stroke=PALETTE["muted"], fill=PALETTE["zoneExt"]),
        zone(*DOCKER_ZONE, "Docker host", "docker compose + persistent volumes",
             dashed=False, stroke=PALETTE["dockerStroke"], fill=PALETTE["zoneDock"],
             path=docker_path),
        zone(*INTERNET_ZONE, "Internet", "External SaaS",
             dashed=True, stroke=PALETTE["muted"], fill=PALETTE["zoneExt"]),
    ]

    # --- nodes -------------------------------------------------------------
    # "user" node uses a custom glyph (SVG-drawn), so everything has vector icons
    ux, uy = P_USER
    user_glyph = f"""
<g transform="translate({ux - 22}, {uy - 50})">
  <circle cx="22" cy="18" r="11" fill="{PALETTE['primary']}"/>
  <path d="M1,46 A21,21 0 0 1 43,46 Z" fill="{PALETTE['primary']}"/>
</g>"""

    user_node = f"""
<g class="node">
  <rect x="{ux - NODE_W/2}" y="{uy - NODE_H/2}" width="{NODE_W}" height="{NODE_H}"
        rx="12" ry="12" fill="{PALETTE['card']}" stroke="{PALETTE['hairline']}"
        stroke-width="1.1" filter="url(#cardshadow)"/>
  {user_glyph}
  <text x="{ux}" y="{uy + NODE_H/2 - 30}" text-anchor="middle"
        font-family="Inter,Helvetica Neue,Arial,sans-serif"
        font-size="15" font-weight="600" fill="{PALETTE['text']}"
        letter-spacing="-0.15">You</text>
  <text x="{ux}" y="{uy + NODE_H/2 - 13}" text-anchor="middle"
        font-family="Inter,Helvetica Neue,Arial,sans-serif"
        font-size="10.5" font-weight="500" fill="{PALETTE['muted']}">
    Browser · Kibana UI
  </text>
</g>"""

    net_node    = node(*P_NET, "Network devices", "Routers, firewalls, IoT",
                       icon_kind="svg", icon_data=network_inner, icon_size=44)
    remote_node = node(*P_REMOTE, "Remote agents", "Elastic Agents off-host",
                       icon_kind="png", icon_data=icon_agent, icon_size=46)

    traefik_node = node(*P_TRAEFIK, "Traefik", "Reverse proxy · ACME · L4",
                        icon_kind="svg", icon_data=traefik_inner, icon_size=46)

    kibana_node = node(*P_KIBANA, "Kibana", "Dashboards · SIEM · Fleet UI",
                       icon_kind="png", icon_data=icon_kb, icon_size=46)
    fleet_node  = node(*P_FLEET, "Fleet Server", "Agent enrolment · policy",
                       icon_kind="png", icon_data=icon_agent, icon_size=46)
    agent_node  = node(*P_AGENT, "Elastic Agent", "Syslog intake · host metrics",
                       icon_kind="png", icon_data=icon_agent, icon_size=46)

    es_block = es_node(*P_ES)

    cf_node = node(*P_CF, "Cloudflare", "DNS-01 ACME",
                   icon_kind="svg", icon_data=cloudflare_inner, icon_size=40,
                   w=150, h=100)

    # ---------------------------------------------------------------------
    # EDGE ROUTING (orthogonal, minimum-elbow, port-based)
    # ---------------------------------------------------------------------
    # Every edge is a polyline of pure H / V segments with a fixed 8px fillet
    # at each 90 degree turn. We minimise elbows by picking the nearest
    # perpendicular face of each node as its port (top / bottom / left /
    # right), so arrows land perpendicular and no line runs parallel to a
    # node's edge. Parallel flows sharing a port share a lane; lanes are
    # offset by >=16px to avoid the <6px near-miss rule.
    # ---------------------------------------------------------------------

    # Node edge helpers
    def right_of(p):
        return (p[0] + NODE_W / 2, p[1])
    def left_of(p):
        return (p[0] - NODE_W / 2, p[1])
    def top_of(p, dx=0):
        return (p[0] + dx, p[1] - NODE_H / 2)
    def bottom_of(p, dx=0):
        return (p[0] + dx, p[1] + NODE_H / 2)

    # ES is a larger card (260x190) -- custom edge helpers.
    ES_W, ES_H = 260, 190
    def es_left(dy=0):
        return (P_ES[0] - ES_W / 2, P_ES[1] + dy)
    def es_top(dx=0):
        return (P_ES[0] + dx, P_ES[1] - ES_H / 2)
    def es_bottom(dx=0):
        return (P_ES[0] + dx, P_ES[1] + ES_H / 2)

    # Traefik geometry
    tL   = P_TRAEFIK[0] - NODE_W / 2          # 436
    tR   = P_TRAEFIK[0] + NODE_W / 2          # 604
    tTop = P_TRAEFIK[1] - NODE_H / 2          # 426
    tBot = P_TRAEFIK[1] + NODE_H / 2          # 534

    LINE_W  = 2.4   # uniform stroke width for coloured flows
    MUTED_W = 1.6   # uniform stroke width for muted service-internal links

    # Traefik port layout -------------------------------------------------
    # LEFT edge: 3 inbound lanes from the west column (24px spacing).
    IN_USER   = (tL, tTop + 24)        # 450
    IN_NET    = (tL, P_TRAEFIK[1])     # 480 -- aligned w/ Network (straight)
    IN_REMOTE = (tL, tBot - 24)        # 510

    # RIGHT edge: 1 aligned outbound (Fleet) -- Kibana and Agent exit from
    # top/bottom because Fleet blocks the direct east path at y=480.
    OUT_FLEET = (tR, P_TRAEFIK[1])     # 480 -- straight line to Fleet

    # TOP edge: Cloudflare ACME + Kibana outbound (Kibana sits above).
    PORT_ACME   = (P_TRAEFIK[0] - 30, tTop)  # 490
    PORT_KB_OUT = (P_TRAEFIK[0] + 30, tTop)  # 550

    # BOTTOM edge: Agent outbound, amber return (from Agent), amber out.
    # Laid out west to east with >=60px between each port.
    PORT_AMB_IN    = (P_TRAEFIK[0] - 60, tBot)  # 460 -- amber return
    PORT_AGENT_OUT = (P_TRAEFIK[0],      tBot)  # 520 -- pink: Traefik -> Agent
    PORT_AMB_OUT   = (P_TRAEFIK[0] + 60, tBot)  # 580 -- amber outbound

    # Dedicated x-channel for inbound risers from the west column.
    CH_INBOUND = 396

    # Horizontal bus corridors (uniform discipline: each bus carries exactly
    # one flow, and no bus shares a y with any node's edge).
    Y_KB_BUS        = 370   # above Fleet (426), well below Kibana (314)
    Y_AGENT_BUS     = 600   # below Fleet (534), above Agent (646)
    # Y_AMBER_OUT_BUS = 615: routed SOUTH of the Elasticsearch card bottom
    # (y=575) so the horizontal run never passes through the ES body before
    # its final vertical approach. Sits between Fleet bottom (534) and
    # Agent top (646).
    Y_AMBER_OUT_BUS = 615
    Y_AMBER_RETURN  = P_AGENT[1]   # 700 -- Agent's own centre y

    # ES entry points.
    es_top_y = P_ES[1] - ES_H / 2     # 385

    flows = []

    # ---- BLUE: User -> Traefik -> Kibana --------------------------------
    # Source -> channel -> lane (2 elbows). Source-side corner keeps the
    # vertical run off Traefik's edge.
    flows.append(ortho_path([
        right_of(P_USER),
        (CH_INBOUND, P_USER[1]),
        (CH_INBOUND, IN_USER[1]),
        IN_USER,
    ], PALETTE["primary"], width=LINE_W))
    # Traefik -> Kibana: exit Traefik TOP (Kibana is above), rise to Y_KB_BUS,
    # run east past Fleet, drop into Kibana BOTTOM. 2 elbows, monotonic.
    flows.append(ortho_path([
        PORT_KB_OUT,
        (PORT_KB_OUT[0], Y_KB_BUS),
        (P_KIBANA[0], Y_KB_BUS),
        bottom_of(P_KIBANA),
    ], PALETTE["primary"], width=LINE_W))

    # ---- TEAL: Remote -> Traefik -> Fleet -------------------------------
    flows.append(ortho_path([
        right_of(P_REMOTE),
        (CH_INBOUND, P_REMOTE[1]),
        (CH_INBOUND, IN_REMOTE[1]),
        IN_REMOTE,
    ], PALETTE["teal"], width=LINE_W))
    # Traefik -> Fleet: STRAIGHT horizontal.
    flows.append(ortho_path([
        OUT_FLEET,
        left_of(P_FLEET),
    ], PALETTE["teal"], width=LINE_W))

    # ---- PINK (dashed): Network -> Traefik -> Agent ---------------------
    # Network is aligned with Traefik centre -- STRAIGHT horizontal.
    flows.append(ortho_path([
        right_of(P_NET),
        IN_NET,
    ], PALETTE["pink"], width=LINE_W, dashed=True))
    # Traefik -> Agent: exit Traefik BOTTOM (not right, so we avoid Fleet),
    # run south to Y_AGENT_BUS, east to Agent's x, north into Agent TOP.
    flows.append(ortho_path([
        PORT_AGENT_OUT,
        (PORT_AGENT_OUT[0], Y_AGENT_BUS),
        (P_AGENT[0], Y_AGENT_BUS),
        top_of(P_AGENT),
    ], PALETTE["pink"], width=LINE_W, dashed=True))

    # ---- AMBER: Agent -> Traefik (return) -> Elasticsearch --------------
    # Return leg: leave Agent LEFT, run west at y=Y_AMBER_RETURN (=Agent y)
    # directly to a column beneath Traefik, then north into Traefik BOTTOM.
    # Single L-elbow.
    agent_left = left_of(P_AGENT)
    flows.append(ortho_path([
        agent_left,
        (PORT_AMB_IN[0], Y_AMBER_RETURN),
        PORT_AMB_IN,
    ], PALETTE["amber"], width=LINE_W))
    # Outbound leg: exit Traefik BOTTOM at PORT_AMB_OUT, south to
    # Y_AMBER_OUT_BUS, east to ES centre x, north into ES BOTTOM.
    flows.append(ortho_path([
        PORT_AMB_OUT,
        (PORT_AMB_OUT[0], Y_AMBER_OUT_BUS),
        (P_ES[0], Y_AMBER_OUT_BUS),
        es_bottom(),
    ], PALETTE["amber"], width=LINE_W))

    # ---- MUTED service-internal: Kibana -> ES, Fleet -> ES --------------
    # Kibana -> ES: exit Kibana RIGHT at y=260, run east, drop into ES TOP.
    # Single L-elbow.
    flows.append(ortho_path([
        right_of(P_KIBANA),
        (P_ES[0], P_KIBANA[1]),
        es_top(),
    ], PALETTE["muted"], width=MUTED_W, opacity=0.7))
    # Fleet -> ES: STRAIGHT horizontal at y=480.
    flows.append(ortho_path([
        right_of(P_FLEET),
        es_left(),
    ], PALETTE["muted"], width=MUTED_W, opacity=0.7))

    # ---- DASHED MUTED: Traefik -> Cloudflare (ACME) ---------------------
    # Single L-elbow: rise from Traefik top to Cloudflare's centre y, run
    # east across the upper band, and land on Cloudflare's LEFT edge. The
    # horizontal run crosses out of the Docker zone (at x=1260) and into the
    # Internet zone, making the control-plane boundary crossing explicit.
    CF_W, CF_H = 150, 100
    cf_left = (P_CF[0] - CF_W / 2, P_CF[1])   # (1425, 175)
    Y_ACME = P_CF[1]                          # 175 -- cloudflare centre y
    flows.append(ortho_path([
        PORT_ACME,
        (PORT_ACME[0], Y_ACME),
        cf_left,
    ], PALETTE["muted"], width=MUTED_W, dashed=True, opacity=0.75))

    # --- labels -----------------------------------------------------------
    # Every label sits on the longest horizontal run of its edge, lifted by
    # the uniform LABEL_OFFSET above the stroke.
    labels = []

    # Inbound elbow labels (User, Remote): sit on the source's horizontal leg.
    labels.append(badge((right_of(P_USER)[0]   + CH_INBOUND) / 2,
                        P_USER[1]   - LABEL_OFFSET, ":443", PALETTE["primary"]))
    labels.append(badge((right_of(P_REMOTE)[0] + CH_INBOUND) / 2,
                        P_REMOTE[1] - LABEL_OFFSET, ":443", PALETTE["teal"]))
    # Network's leg is a straight line -- midpoint.
    labels.append(badge((right_of(P_NET)[0] + IN_NET[0]) / 2,
                        P_NET[1] - LABEL_OFFSET, "TCP/UDP :514", PALETTE["pink"]))

    # Outbound to Kibana: sits on the Y_KB_BUS horizontal run.
    labels.append(badge((PORT_KB_OUT[0] + P_KIBANA[0]) / 2,
                        Y_KB_BUS - LABEL_OFFSET,
                        "kibana.example.com :5601", PALETTE["primary"]))
    # Outbound to Fleet: midpoint of straight line.
    labels.append(badge((OUT_FLEET[0] + left_of(P_FLEET)[0]) / 2,
                        OUT_FLEET[1] - LABEL_OFFSET,
                        "fleet.example.com :8220", PALETTE["teal"]))
    # Outbound to Agent: sits on the Y_AGENT_BUS horizontal run.
    labels.append(badge((PORT_AGENT_OUT[0] + P_AGENT[0]) / 2,
                        Y_AGENT_BUS - LABEL_OFFSET,
                        "syslog.example.com :5514", PALETTE["pink"]))

    # Amber outbound: centred on the corridor segment AFTER Fleet's right
    # edge and BEFORE Elasticsearch's left edge, so the pill never overlaps
    # either node (Fleet right = 984, ES left = 1250).
    labels.append(badge((984 + (P_ES[0] - ES_W / 2)) / 2,
                        Y_AMBER_OUT_BUS - LABEL_OFFSET,
                        "es.example.com :9200", PALETTE["amber"]))
    # Amber return (Y_AMBER_RETURN = agent centre y).
    labels.append(badge((agent_left[0] + PORT_AMB_IN[0]) / 2,
                        Y_AMBER_RETURN - LABEL_OFFSET,
                        "logs + metrics", PALETTE["amber"]))

    # Inline muted labels (no badge) for Kibana -> ES and Fleet -> ES.
    def inline_label(x, y, text, color):
        return (f'<text x="{x}" y="{y}" text-anchor="middle" '
                f'font-family="JetBrains Mono,SF Mono,Menlo,monospace" '
                f'font-size="10" font-weight="500" fill="{color}" '
                f'letter-spacing="0.1">{esc(text)}</text>')
    # Kibana -> ES horizontal at y=260, from x=984 to x=1380.
    labels.append(inline_label((right_of(P_KIBANA)[0] + P_ES[0]) / 2,
                               P_KIBANA[1] - 10, "queries  :9200", PALETTE["muted"]))
    # Fleet -> ES horizontal at y=480, from x=984 to x=1270.
    labels.append(inline_label((right_of(P_FLEET)[0] + es_left()[0]) / 2,
                               P_FLEET[1] - 10, "metadata  :9200", PALETTE["muted"]))

    # Cloudflare dashed badge: sits ABOVE the horizontal ACME run, centred on
    # the long Docker-zone portion of the segment so it stays clear of the
    # Internet zone's title block (y=154) and well above Kibana's top edge
    # (y=206).
    labels.append(badge((PORT_ACME[0] + cf_left[0]) / 2,
                        Y_ACME - LABEL_OFFSET,
                        "DNS-01 ACME", PALETTE["muted"]))

    # --- legend -----------------------------------------------------------
    leg_x, leg_y = 64, 900
    leg_w, leg_h = W - 128, 92
    legend_items = [
        (PALETTE["primary"], "User access",       "Browser  →  :443  →  Kibana", False),
        (PALETTE["teal"],    "Agent management",  "Remote agent  →  Fleet :8220", False),
        (PALETTE["pink"],    "Syslog pipeline",   "Network  →  :514  →  Agent :5514", True),
        (PALETTE["amber"],   "Telemetry",         "Agent  →  :9200  →  Elasticsearch", False),
    ]
    legend = [f'<rect x="{leg_x}" y="{leg_y}" width="{leg_w}" height="{leg_h}" '
              f'rx="12" fill="#FFFFFF" stroke="{PALETTE["hairline"]}" '
              f'stroke-width="1" filter="url(#cardshadow)"/>']
    legend.append(f'<text x="{leg_x + 24}" y="{leg_y + 28}" '
                  f'font-family="Inter,Helvetica Neue,Arial,sans-serif" '
                  f'font-size="10.5" font-weight="700" fill="{PALETTE["muted"]}" '
                  f'letter-spacing="2.6">DATA FLOWS</text>')
    col_w = (leg_w - 48) / 4
    for i, (col, title, sub, dashed) in enumerate(legend_items):
        x0 = leg_x + 24 + i * col_w
        y0 = leg_y + 60
        dash_attr = ' stroke-dasharray="7 6"' if dashed else ""
        legend.append(
            f'<line x1="{x0}" y1="{y0}" x2="{x0 + 44}" y2="{y0}" '
            f'stroke="{col}" stroke-width="3.2" stroke-linecap="round"{dash_attr}/>')
        legend.append(
            f'<circle cx="{x0 + 44}" cy="{y0}" r="3" fill="{col}"/>')
        legend.append(
            f'<text x="{x0 + 60}" y="{y0 - 2}" '
            f'font-family="Inter,Helvetica Neue,Arial,sans-serif" '
            f'font-size="13.5" font-weight="600" fill="{PALETTE["text"]}" '
            f'letter-spacing="-0.1">{esc(title)}</text>')
        legend.append(
            f'<text x="{x0 + 60}" y="{y0 + 18}" '
            f'font-family="JetBrains Mono,SF Mono,Menlo,monospace" '
            f'font-size="10.5" fill="{PALETTE["muted"]}">{esc(sub)}</text>')

    # --- footer ------------------------------------------------------------
    footer = f"""
<g class="footer">
  <text x="{W - 64}" y="{H - 24}" text-anchor="end"
        font-family="Inter,Helvetica Neue,Arial,sans-serif"
        font-size="11" font-weight="500" fill="{PALETTE['muted']}"
        letter-spacing="0.3">github.com/jamesagarside/elastic-at-home</text>
</g>"""

    svg = f"""<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
     viewBox="0 0 {W} {H}" width="{W}" height="{H}"
     font-family="Inter,Helvetica Neue,Arial,sans-serif">
{defs}
  <rect width="{W}" height="{H}" fill="{PALETTE['bg']}"/>
  <rect width="{W}" height="{H}" fill="url(#dotgrid)" opacity="0.5"/>
  {header}
  {''.join(zones)}
  <!-- flows -->
  {''.join(flows)}
  <!-- nodes -->
  {user_node}
  {net_node}
  {remote_node}
  {traefik_node}
  {kibana_node}
  {fleet_node}
  {agent_node}
  {es_block}
  {cf_node}
  <!-- flow labels -->
  {''.join(labels)}
  <!-- legend -->
  {''.join(legend)}
  {footer}
</svg>
"""
    return svg


if __name__ == "__main__":
    import sys
    sys.stdout.write(build_svg())
