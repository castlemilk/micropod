"""Render the two Gamma figures from gamma_contrasts.py with ReportLab and librsvg."""
import argparse
import json
import subprocess
from pathlib import Path

from reportlab.graphics import renderSVG
from reportlab.graphics.shapes import Circle, Drawing, Line, Polygon, Rect, String
from reportlab.lib.colors import HexColor

W, H = 900, 455
INK = "#18232c"
MUTED = "#475966"
GRID = "#d8e0e4"
BLUE = "#17619c"
TEAL = "#007668"
GRAY = "#667787"


def label(drawing, x, y, text, size=13, bold=False, color=INK, anchor="start"):
    drawing.add(String(x, H - y, text, fontName="Helvetica-Bold" if bold else "Helvetica",
                       fontSize=size, fillColor=HexColor(color), textAnchor=anchor))


def line(drawing, x1, y1, x2, y2, color=GRID, width=1):
    drawing.add(Line(x1, H-y1, x2, H-y2, strokeColor=HexColor(color), strokeWidth=width))


def point(drawing, x, y, radius, color, hollow=False):
    drawing.add(Circle(x, H-y, radius, fillColor=HexColor("#ffffff" if hollow else color),
                       strokeWidth=1.1, strokeColor=HexColor(color)))


def square(drawing, x, y, color):
    drawing.add(Rect(x-3.4, H-y-3.4, 6.8, 6.8, fillColor=HexColor(color), strokeColor=None))


def paper(title, subtitle):
    d = Drawing(W, H)
    d.add(Rect(0, 0, W, H, fillColor=HexColor("#ffffff"), strokeColor=None))
    label(d, 32, 46, title, 26, True)
    label(d, 33, 72, subtitle, 14, color=MUTED)
    return d


def relay_figure(contrasts):
    d = paper("Host relay throughput with one change at a time",
              "Gamma host relay  /  32 local socket streams  /  median paired throughput change")
    x0, x1, low, high = 225, 660, -25, 125
    xpos = lambda v: x0 + (v-low)/(high-low)*(x1-x0)
    for tick in (-25, 0, 25, 50, 75, 100, 125):
        x = xpos(tick)
        line(d, x, 119, x, 320, MUTED if tick == 0 else GRID, 1.25 if tick == 0 else .65)
        label(d, x, 340, f"{tick}%", 11, color=MUTED, anchor="middle")
    label(d, 710, 111, "Paired gain", 12, True)
    label(d, 853, 111, "Pairs", 12, True, anchor="end")
    for y, group, heading, sub, color in [
        (140, "distribution", "Listener distribution", "2 workers, 128 events per callback", BLUE),
        (246, "workers", "Two to four workers", "Staggered listeners, 128 events", TEAL),
    ]:
        label(d, 32, y-22, heading, 16, True, color=color)
        label(d, 32, y-5, sub, 11, color=MUTED)
        for i, ports in enumerate((1, 32)):
            yy = y+22+i*36
            v = contrasts[f"{group}_{ports}"]
            gain = 100*(v["median_ratio"]-1)
            xx = xpos(gain)
            label(d, 32, yy+4, f"{ports} logical {'port' if ports == 1 else 'ports'}", 14)
            label(d, 710, yy+5, f"{gain:+.1f}%", 18, True, color=color)
            label(d, 853, yy+4, str(len(v["paired_rounds"])), 14, anchor="end")
            if v["bootstrap_ci95"]:
                a,b = (xpos(100*(n-1)) for n in v["bootstrap_ci95"])
                line(d, a, yy, b, yy, color, 2)
                line(d, a, yy-4, a, yy+4, color, 1.5)
                line(d, b, yy-4, b, yy+4, color, 1.5)
                point(d, xx, yy, 5, color)
            else:
                for n in v["paired_ratios"]:
                    point(d, xpos(100*(n-1)), yy, 3.5, color, hollow=True)
                d.add(Polygon([xx,H-yy+5,xx+5,H-yy,xx,H-yy-5,xx-5,H-yy],
                              fillColor=HexColor(color),strokeColor=HexColor(color)))
    line(d, 32, 358, 868, 358)
    label(d, 32, 383, "Distribution", 12, True, BLUE)
    label(d, 112, 383, "Six-second windows. Whiskers show 95% paired bootstrap intervals.", 12, color=MUTED)
    label(d, 32, 405, "Worker count", 12, True, TEAL)
    label(d, 120, 405, "Two-second screen. Symbols show all three pairs. The diamond marks their median.", 12, color=MUTED)
    label(d, 32, 432, "The earlier +65.6% single-port result also shortened the callback to 24 events.", 12, color=MUTED)
    return d


def vm_figure(data):
    c = data["contrasts"]["vm_peer_4"]
    d = paper("Host-published TCP through the VM",
              "Gamma  /  4 vCPUs per VM  /  one published port  /  32 downloads and 40 fresh HTTP requests/s")
    arms = [("confirm-micropod", "Micropod", TEAL, point), ("confirm-orb", "OrbStack", GRAY, square)]
    for i,(key,name,color,_) in enumerate(arms):
        a=c["arms"][key]
        x=32+310*i
        label(d, x, 112, name, 15, True, color)
        label(d, x, 137, f"{a['mib_s']:,.0f} MiB/s", 21, True)
        label(d, x+147, 135, f"{a['clean']}/{a['attempts']} clean", 12, color=MUTED)
    x0, x1, top, bottom = 82, 848, 172, 337
    xpos = lambda i: x0 + (i-1)*(x1-x0)/15
    ypos = lambda y: bottom - y/6000*(bottom-top)
    for tick in (0,2000,4000,6000):
        yy=ypos(tick)
        line(d, x0, yy, x1, yy)
        label(d, x0-10, yy+4, f"{tick:,}", 11, color=MUTED, anchor="end")
    label(d, 33, 160, "MiB/s", 11, color=MUTED)
    for key,name,color,mark in arms:
        last = None
        for r in [r for r in data["vm_holdout"] if r["arm"]==key]:
            x=xpos(r["round"])
            if not r["clean"]:
                last = None
                line(d, x-4, bottom-4, x+4, bottom+4, GRAY, 1.7)
                line(d, x-4, bottom+4, x+4, bottom-4, GRAY, 1.7)
                continue
            y=ypos(r["mib_s"])
            if last:
                line(d, *last, x, y, color, 1.6)
            if mark is point:
                point(d, x, y, 3.9, color)
            else:
                square(d, x, y, color)
            last=(x,y)
    for i in range(1,17):
        label(d, xpos(i), 356, str(i), 11, color=MUTED, anchor="middle")
    label(d, x1, 375, "Matched round", 11, color=MUTED, anchor="end")
    line(d, 32, 385, 868, 385)
    lo,hi=c["bootstrap_ci95"]
    label(d, 32, 408, f"Micropod paired difference   {100*(c['median_ratio']-1):+.1f}%", 14, True)
    label(d, 313, 408, f"95% interval {100*(lo-1):+.1f}% to {100*(hi-1):+.1f}% across {len(c['paired_rounds'])} clean pairs.", 13, color=MUTED)
    label(d, 32, 432, "×  OrbStack round 12 had one fresh-request EOF. Median rates use each engine’s clean rounds.", 12, color=MUTED)
    return d


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path)
    args=parser.parse_args()
    data=json.loads(args.evidence.read_text())
    for name,d in [("gamma-host-relay-gains", relay_figure(data["contrasts"])), ("gamma-end-to-end-vm", vm_figure(data))]:
        svg = renderSVG.drawToString(d)
        subprocess.run(["rsvg-convert", "--width", "1440", "-o", args.evidence.parent / (name+".png")],
                       input=svg.encode() if isinstance(svg,str) else svg, check=True)
