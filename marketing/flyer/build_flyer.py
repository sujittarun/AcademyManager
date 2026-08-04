#!/usr/bin/env python3
"""The FLYER — the short one.

Its whole job is: catch the eye, say what this is, give a price anchor,
and make it obvious how to reach you. Detail belongs in the demo video
and in the sales sheet (build.py), not here.

    python3 marketing/flyer/build_flyer.py
"""
import base64, pathlib, subprocess

HERE = pathlib.Path(__file__).parent
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
MARK = base64.b64encode((HERE / "_mark.jpg").read_bytes()).decode()

BENEFITS = [
    ("Your own branded app",        "your name, your logo, your web address"),
    ("Fees that price themselves",  "every student billed the right amount, automatically"),
    ("WhatsApp reminders",          "polite, on a schedule, and they stop on their own"),
    ("UPI straight to your account","no gateway, no cut, proof stored with the payment"),
    ("Attendance in seconds",       "courtside, on a phone"),
    ("Coach logins for the register","they never see fees or parents' numbers"),
]

TIERS = [
    ("Starter", "up to 50 students",  "&#8377;899",   False),
    ("Growth",  "up to 100 students", "&#8377;1,999", True),
    ("Pro",     "up to 150 students", "&#8377;3,999", False),
    ("Custom",  "150+ &middot; chains", "Let&rsquo;s talk", False),
]

benefits = "".join(
    f'<li><i>✓</i><div><b>{t}</b><span>{s}</span></div></li>' for t, s in BENEFITS
)
tiers = "".join(
    f'<div class="t{" pop" if pop else ""}">{"<em>most popular</em>" if pop else ""}'
    f'<h3>{n}</h3><small>{c}</small><strong>{p}</strong>'
    f'{"<span>/month</span>" if p.startswith("&#8377;") else "<span>&nbsp;</span>"}</div>'
    for n, c, p, pop in TIERS
)

def page(W, H):
  return f"""<!DOCTYPE html><html><head><meta charset="utf-8">
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800;900&display=swap" rel="stylesheet">
<style>
 :root{{--ink:#16241E;--g900:#1F3A2F;--g700:#2C5646;--g500:#4A7261;
        --sage:#8FA396;--pale:#DFE8E1;--cream:#F6F3EC;--line:#E4DFD3;
        --terra:#A8503A;--muted:#6E7B72}}
 *{{margin:0;padding:0;box-sizing:border-box}}
 body{{width:{W}px;height:{H}px;font-family:Inter,Helvetica,Arial,sans-serif;
       background:#fff;color:var(--ink);-webkit-font-smoothing:antialiased;
       display:flex;flex-direction:column}}

 .top{{background:linear-gradient(180deg,#F8F5EF,#F1EDE3);padding:52px 70px 44px;
       display:flex;align-items:center;gap:34px;border-bottom:4px solid var(--g700)}}
 .top img{{width:250px;height:163px;object-fit:cover;border-radius:14px;flex:none;mix-blend-mode:multiply}}
 .wm{{font-size:62px;font-weight:800;letter-spacing:-.037em;line-height:1;color:var(--g900)}}
 .wm span{{color:var(--g500)}}
 .tag{{margin-top:12px;font-size:14px;font-weight:700;letter-spacing:.26em;
       color:var(--sage);text-transform:uppercase}}

 .hero{{padding:0 70px}}
 .hero h1{{font-size:66px;font-weight:800;letter-spacing:-.04em;line-height:1.05;color:var(--g900)}}
 .hero h1 em{{font-style:normal;color:var(--terra)}}
 .hero p{{margin-top:22px;font-size:26px;line-height:1.45;color:var(--muted);font-weight:500;max-width:900px}}

 ul{{list-style:none;padding:0 70px;display:grid;grid-template-columns:1fr 1fr;gap:34px 48px}}
 li{{display:flex;gap:15px;align-items:flex-start}}
 li i{{font-style:normal;width:33px;height:33px;border-radius:50%;background:var(--g700);color:#fff;
       font-size:15px;font-weight:800;display:grid;place-items:center;flex:none;margin-top:2px}}
 li b{{display:block;font-size:22px;font-weight:700;letter-spacing:-.018em;line-height:1.25}}
 li span{{display:block;font-size:16.5px;color:var(--muted);margin-top:3px;font-weight:500;line-height:1.35}}

 .price{{margin:0 70px;background:var(--cream);border:1px solid var(--line);
         border-radius:20px;padding:32px 30px}}
 .price .lbl{{font-size:14px;font-weight:700;letter-spacing:.16em;text-transform:uppercase;
              color:var(--sage);text-align:center}}
 .row{{display:grid;grid-template-columns:repeat(4,1fr);gap:16px;margin-top:20px}}
 .t{{background:#fff;border:1.5px solid var(--line);border-radius:15px;padding:22px 12px 20px;
     text-align:center;position:relative}}
 .t.pop{{border-color:var(--g700);border-width:2.5px}}
 .t em{{position:absolute;top:-11px;left:50%;transform:translateX(-50%);background:var(--terra);
        color:#fff;font-size:10px;font-weight:800;letter-spacing:.1em;text-transform:uppercase;
        padding:3px 12px;border-radius:20px;font-style:normal;white-space:nowrap}}
 .t h3{{font-size:19px;font-weight:800;letter-spacing:-.02em;color:var(--g900)}}
 .t small{{display:block;font-size:13.5px;color:var(--muted);margin-top:3px;font-weight:600}}
 .t strong{{display:block;font-size:35px;font-weight:900;letter-spacing:-.035em;
            color:var(--g700);margin-top:12px;line-height:1}}
 .t.pop strong{{color:var(--g900)}}
 .t span{{display:block;font-size:13px;color:var(--muted);font-weight:600;margin-top:3px}}
 .foot-note{{text-align:center;font-size:14.5px;color:var(--muted);margin-top:18px;font-weight:500}}

 .mid{{flex:1;display:flex;flex-direction:column;justify-content:space-evenly}}
 .proof{{margin:0 70px;padding:22px 0 0;text-align:center;
          border-top:1px solid var(--line)}}
 .proof b{{display:block;font-size:19px;font-weight:800;letter-spacing:-.015em;color:var(--g900)}}
 .proof span{{display:block;font-size:16px;color:var(--muted);margin-top:7px;font-weight:500}}

 .cta{{background:var(--g900);color:#fff;padding:46px 70px;
       display:flex;align-items:center;justify-content:space-between;gap:30px}}
 .cta h2{{font-size:34px;font-weight:800;letter-spacing:-.028em;line-height:1.15}}
 .cta p{{font-size:17px;color:#A6C2B4;margin-top:8px;font-weight:500}}
 .num{{text-align:right;flex:none}}
 .num .n{{font-size:38px;font-weight:900;letter-spacing:-.03em;white-space:nowrap}}
 .num .e{{font-size:17px;color:#A6C2B4;margin-top:7px;font-weight:600}}
</style></head><body>

 <div class="top">
   <img src="data:image/jpeg;base64,{MARK}" alt="">
   <div><div class="wm">Academy<span>Manager</span></div>
        <div class="tag">Sports &nbsp;·&nbsp; Operations &nbsp;·&nbsp; Insight</div></div>
 </div>

 <div class="mid">
 <div class="hero">
   <h1>Your academy&rsquo;s<br><em>own app.</em></h1>
   <p>Students, fees, attendance and WhatsApp reminders &mdash;
      in one place, run from your phone.</p>
 </div>

 <ul>{benefits}</ul>

 <div class="price">
   <div class="lbl">Simple pricing &middot; by academy size</div>
   <div class="row">{tiers}</div>
   <div class="foot-note">Every plan is the full app. Yearly plans get 2 months free. GST extra.</div>
 </div>

 <div class="proof">
   <b>Built with real academies</b>
   <span>badminton &middot; tennis &middot; cricket &middot; multi-sport &mdash; across Hyderabad &amp; Bengaluru</span>
 </div>

 </div>

 <div class="cta">
   <div><h2>See it on your own numbers.</h2>
        <p>A 15-minute walkthrough &mdash; or ask me for the 2-minute video.</p></div>
   <div class="num"><div class="n">99515 97567</div>
        <div class="e">tarun.sujit@gmail.com</div></div>
 </div>

</body></html>"""

for name, W, H in [("academy-manager-flyer", 1240, 1754),      # A4, for print
                   ("academy-manager-flyer-social", 1240, 1550)]:  # 4:5, for WhatsApp
    html_path = HERE / f"{name}.html"
    png_path  = HERE / f"{name}.png"
    html_path.write_text(page(W, H))
    subprocess.run([CHROME, "--headless", "--disable-gpu", "--hide-scrollbars",
                    f"--screenshot={png_path}", f"--window-size={W},{H}",
                    "--force-device-scale-factor=2", "--virtual-time-budget=6000",
                    f"file://{html_path}"], check=True, capture_output=True)
    print(f"✓ {png_path.name}  ({W}x{H} @2x)")
