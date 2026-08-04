#!/usr/bin/env python3
"""Build the Academy Manager sales flyer.

The flyer is written as HTML and rendered to PNG with headless Chrome, so
it stays editable: change the CONTENT block below, re-run, get a new
flyer. Nothing here is hand-placed in a design tool.

    python3 marketing/flyer/build.py

Outputs marketing/flyer/academy-manager-flyer.png at 2x (print-usable and
WhatsApp-shareable) plus the .html it came from.
"""
import base64, pathlib, subprocess, sys

HERE = pathlib.Path(__file__).parent
BRANDING = HERE.parent.parent / "assets" / "branding"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"


def b64(path: pathlib.Path) -> str:
    return base64.b64encode(path.read_bytes()).decode()


# The loop mark, cropped from the 1254px master so it stays sharp in print.
mark_src = HERE / "_mark.jpg"
if not mark_src.exists():
    master = BRANDING / "academy-manager-logo-ui-v5-master.png"
    tmp = HERE / "_tmp.png"
    tmp.write_bytes(master.read_bytes())
    subprocess.run(["sips", str(tmp), "--cropOffset", "170", "70", "-c", "730", "1120"],
                   check=True, capture_output=True)
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "92",
                    str(tmp), "--out", str(mark_src)], check=True, capture_output=True)
    tmp.unlink(missing_ok=True)

MARK = b64(mark_src)

HTML = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800;900&display=swap" rel="stylesheet">
<style>
  /* ---- palette sampled from the logo itself ---------------------------
     the loop's greens, the paper cream, and the cricket ball's terracotta */
  :root{
    --ink:#17251F; --green-900:#1F3A2F; --green-700:#2C5646; --green-500:#487260;
    --sage:#8FA396; --sage-pale:#DCE5DE;
    --cream:#F6F3EC; --paper:#FFFFFF; --line:#E3DED2;
    --terra:#A8503A; --terra-pale:#F6EAE5;
    --gold:#B07C33;
    --muted:#6E7B72;
  }
  *{margin:0;padding:0;box-sizing:border-box}
  body{width:1240px;height:1754px;font-family:Inter,-apple-system,Helvetica,Arial,sans-serif;
       background:var(--paper);color:var(--ink);-webkit-font-smoothing:antialiased}
  .sheet{display:flex;flex-direction:column;height:100%}

  /* ---------- header ---------- */
  .head{background:linear-gradient(180deg,#F7F4ED,#F2EEE4);border-bottom:3px solid var(--green-700);
        padding:30px 54px 24px;display:flex;align-items:center;gap:30px}
  .head img{width:210px;height:137px;object-fit:cover;border-radius:12px;flex:none;
            mix-blend-mode:multiply}
  .wm{font-size:52px;font-weight:800;letter-spacing:-.035em;line-height:1;color:var(--green-900)}
  .wm span{color:var(--green-500)}
  .tag{margin-top:9px;font-size:13.5px;font-weight:700;letter-spacing:.24em;color:var(--sage);text-transform:uppercase}
  .pitch{margin-top:13px;font-size:19px;font-weight:600;color:var(--green-700);line-height:1.35;max-width:640px}
  .pitch b{color:var(--terra)}

  /* ---------- section furniture ---------- */
  .sec{padding:0 54px}
  .sec-h{display:flex;align-items:baseline;gap:12px;margin:19px 0 12px}
  .sec-h h2{font-size:20px;font-weight:800;letter-spacing:-.02em;color:var(--green-900)}
  .sec-h p{font-size:13px;color:var(--muted);font-weight:500}
  .rule{flex:1;height:1px;background:var(--line)}

  /* ---------- capability grid ---------- */
  .caps{display:grid;grid-template-columns:repeat(4,1fr);gap:11px}
  .cap{border:1px solid var(--line);border-radius:13px;padding:13px 14px;background:var(--cream)}
  .cap .ico{width:30px;height:30px;border-radius:8px;background:var(--green-700);color:#fff;
            display:grid;place-items:center;font-size:16px;font-weight:800;margin-bottom:8px}
  .cap h3{font-size:13.5px;font-weight:800;letter-spacing:-.01em;line-height:1.2}
  .cap p{font-size:11.5px;color:var(--muted);line-height:1.45;margin-top:4px;font-weight:500}

  /* ---------- access layers ---------- */
  .layers{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}
  .layer{border:1.5px solid var(--line);border-radius:13px;overflow:hidden}
  .layer .lh{padding:9px 14px;font-size:13.5px;font-weight:800;color:#fff;display:flex;align-items:center;gap:8px}
  .layer:nth-child(1) .lh{background:var(--green-700)}
  .layer:nth-child(2) .lh{background:var(--green-500)}
  .layer:nth-child(3) .lh{background:var(--terra)}
  .layer ul{list-style:none;padding:11px 14px 13px}
  .layer li{font-size:11.5px;color:var(--ink);line-height:1.5;padding-left:13px;position:relative;font-weight:500}
  .layer li::before{content:"";position:absolute;left:0;top:7px;width:5px;height:5px;border-radius:50%;background:var(--sage)}

  /* ---------- pricing ---------- */
  .tiers{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}
  .tier{border:1.5px solid var(--line);border-radius:15px;padding:16px 14px;text-align:center;background:var(--paper);position:relative}
  .tier.pop{border-color:var(--green-700);border-width:2.5px;background:linear-gradient(180deg,#F4F9F6,#fff);
            box-shadow:0 8px 22px -12px rgba(44,86,70,.4)}
  .flag{position:absolute;top:-11px;left:50%;transform:translateX(-50%);background:var(--terra);color:#fff;
        font-size:9.5px;font-weight:800;letter-spacing:.1em;padding:3px 11px;border-radius:20px;white-space:nowrap}
  .tier h3{font-size:17px;font-weight:800;letter-spacing:-.02em;color:var(--green-900)}
  .tier .cap-line{font-size:11.5px;color:var(--muted);margin-top:3px;font-weight:600}
  .tier .price{font-size:31px;font-weight:900;letter-spacing:-.035em;color:var(--green-700);margin-top:10px;line-height:1}
  .tier.pop .price{color:var(--green-900)}
  .tier .price small{font-size:13px;font-weight:700;color:var(--muted);letter-spacing:0}
  .tier .yr{font-size:11.5px;color:var(--muted);margin-top:5px;font-weight:600}
  .tier .save{display:inline-block;margin-top:6px;font-size:10px;font-weight:800;color:var(--green-700);
              background:var(--sage-pale);border-radius:20px;padding:2px 9px}
  .tier.ent .price{font-size:25px;color:var(--gold)}

  /* ---------- matrix ---------- */
  table{width:100%;border-collapse:collapse;border:1px solid var(--line);border-radius:12px;overflow:hidden}
  thead th{background:var(--green-900);color:#fff;font-size:11px;font-weight:800;letter-spacing:.07em;
           text-transform:uppercase;padding:9px 10px;text-align:center}
  thead th:first-child{text-align:left;padding-left:14px}
  thead th.pop{background:var(--green-700)}
  thead th.ent{background:var(--gold)}
  tbody td{font-size:11.5px;padding:7px 10px;text-align:center;border-bottom:1px solid #EFEBE1;font-weight:600;color:var(--ink)}
  tbody td:first-child{text-align:left;padding-left:14px;font-weight:700;color:var(--green-900)}
  tbody tr:nth-child(even){background:#FBF9F5}
  tbody tr:last-child td{border-bottom:0}
  td.no{color:#B9C0BA;font-weight:600}
  td.yes{color:var(--green-700);font-weight:800}
  .colpop{background:rgba(72,114,96,.07)}

  /* ---------- footer ---------- */
  .notes{display:grid;grid-template-columns:repeat(3,1fr);gap:11px;margin-top:14px}
  .note{border:1px solid var(--line);border-radius:11px;padding:10px 13px;background:var(--cream);
        display:flex;gap:10px;align-items:flex-start}
  .note .ni{font-size:15px;flex:none}
  .note b{font-size:11.5px;font-weight:800;display:block;color:var(--green-900)}
  .note span{font-size:10.5px;color:var(--muted);line-height:1.4;font-weight:500}

  .addons{display:flex;gap:9px;margin-top:11px}
  .ad{flex:1;border:1px dashed var(--sage);border-radius:11px;padding:9px 12px;background:#FAFCFA}
  .ad b{font-size:11px;font-weight:800;color:var(--green-900);display:block}
  .ad span{font-size:10.5px;color:var(--muted);font-weight:600}

  .foot{margin-top:auto;background:var(--green-900);color:#fff;padding:16px 54px;display:flex;
        align-items:center;justify-content:space-between;gap:20px}
  .foot .cta{font-size:16px;font-weight:800;letter-spacing:-.01em}
  .foot .cta span{display:block;font-size:11.5px;font-weight:500;color:#A9C3B6;margin-top:2px;letter-spacing:0}
  .foot .contact{display:flex;gap:22px;align-items:center}
  .foot .c{display:flex;gap:8px;align-items:center;font-size:13.5px;font-weight:700}
  .foot .c i{font-style:normal;font-size:15px}
</style></head><body><div class="sheet">

  <div class="head">
    <img src="data:image/jpeg;base64,__MARK__" alt="Academy Manager">
    <div>
      <div class="wm">Academy<span>Manager</span></div>
      <div class="tag">Sports &nbsp;·&nbsp; Operations &nbsp;·&nbsp; Insight</div>
      <div class="pitch">__PITCH__</div>
    </div>
  </div>

  <div class="sec">
    <div class="sec-h"><h2>__CAPS_TITLE__</h2><p>__CAPS_SUB__</p><div class="rule"></div></div>
    <div class="caps">__CAPS__</div>

    <div class="sec-h"><h2>Who logs in</h2><p>__LAYERS_SUB__</p><div class="rule"></div></div>
    <div class="layers">__LAYERS__</div>

    <div class="sec-h"><h2>Simple pricing, by active players</h2><p>__PRICE_SUB__</p><div class="rule"></div></div>
    <div class="tiers">__TIERS__</div>

    <div class="sec-h"><h2>What's included</h2><p>__MATRIX_SUB__</p><div class="rule"></div></div>
    __MATRIX__

    <div class="notes">__NOTES__</div>
    <div class="addons">__ADDONS__</div>
  </div>

  <div class="foot">
    <div class="cta">__CTA__<span>__CTA_SUB__</span></div>
    <div class="contact">
      <div class="c"><i>✆</i>__PHONE__</div>
      <div class="c"><i>✉</i>__EMAIL__</div>
    </div>
  </div>

</div></body></html>"""


def cap(icon, title, body):
    return f'<div class="cap"><div class="ico">{icon}</div><h3>{title}</h3><p>{body}</p></div>'


def layer(name, items):
    lis = "".join(f"<li>{i}</li>" for i in items)
    return f'<div class="layer"><div class="lh">{name}</div><ul>{lis}</ul></div>'


def tier(name, players, price, yearly, save=None, pop=False, ent=False):
    cls = "tier" + (" pop" if pop else "") + (" ent" if ent else "")
    flag = '<div class="flag">MOST POPULAR</div>' if pop else ""
    sv = f'<div class="save">{save}</div>' if save else ""
    yr = f'<div class="yr">{yearly}</div>' if yearly else ""
    return (f'<div class="{cls}">{flag}<h3>{name}</h3><div class="cap-line">{players}</div>'
            f'<div class="price">{price}</div>{yr}{sv}</div>')


def matrix(rows):
    head = ('<thead><tr><th>Feature</th><th>Starter</th><th class="pop">Growth</th>'
            '<th>Pro</th><th class="ent">Enterprise</th></tr></thead>')
    body = ""
    for label, vals in rows:
        tds = ""
        for i, v in enumerate(vals):
            cls = "colpop" if i == 1 else ""
            if v == "—":
                cls += " no"
            elif v in ("Yes", "Included"):
                cls += " yes"
            tds += f'<td class="{cls.strip()}">{v}</td>'
        body += f"<tr><td>{label}</td>{tds}</tr>"
    return f"<table>{head}<tbody>{body}</tbody></table>"


def note(icon, title, body):
    return f'<div class="note"><div class="ni">{icon}</div><div><b>{title}</b><span>{body}</span></div></div>'


def addon(title, price):
    return f'<div class="ad"><b>{title}</b><span>{price}</span></div>'


# ======================================================================
# CONTENT — edit here, re-run, done.
# ======================================================================
sys.path.insert(0, str(HERE))
from content import CONTENT as C
C = dict(C)
C["MATRIX"] = matrix(C.pop("MATRIX_ROWS"))

html = HTML.replace("__MARK__", MARK)
for k, v in C.items():
    html = html.replace(f"__{k}__", v)

out_html = HERE / "academy-manager-flyer.html"
out_png = HERE / "academy-manager-flyer.png"
out_html.write_text(html)

subprocess.run([CHROME, "--headless", "--disable-gpu", "--hide-scrollbars",
                f"--screenshot={out_png}", "--window-size=1240,1754",
                "--force-device-scale-factor=2", "--virtual-time-budget=6000",
                f"file://{out_html}"], check=True, capture_output=True)
print(f"✓ {out_png}")
subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(out_png)])
