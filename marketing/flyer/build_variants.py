#!/usr/bin/env python3
"""Four alternative flyers, each selling a different way.

  B  dark      — premium, high contrast; stands out in a white WhatsApp feed
  C  poster    — logo-led, almost no copy; brand first
  D  contrast  — "right now" vs "with Academy Manager"; sells the pain
  E  message   — the WhatsApp reminder itself as the hero; sells the proof

All 1240x1550 (4:5, the shape a phone shows best) at 2x.

    python3 marketing/flyer/build_variants.py
"""
import base64, pathlib, subprocess

HERE = pathlib.Path(__file__).parent
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
MARK = base64.b64encode((HERE / "_mark.jpg").read_bytes()).decode()
W, H = 1240, 1550

BASE = """
 :root{--ink:#16241E;--g900:#1F3A2F;--g700:#2C5646;--g500:#4A7261;
        --sage:#8FA396;--cream:#F6F3EC;--line:#E4DFD3;--terra:#A8503A;--muted:#6E7B72}
 *{margin:0;padding:0;box-sizing:border-box}
 body{width:%dpx;height:%dpx;font-family:Inter,Helvetica,Arial,sans-serif;
      -webkit-font-smoothing:antialiased;display:flex;flex-direction:column}
""" % (W, H)

FONT = ('<link href="https://fonts.googleapis.com/css2?'
        'family=Inter:wght@400;500;600;700;800;900&display=swap" rel="stylesheet">')


def shell(css, body):
    return (f'<!DOCTYPE html><html><head><meta charset="utf-8">{FONT}'
            f'<style>{BASE}{css}</style></head><body>{body}</body></html>')


# ══════════════════════════════════════════════════════════════════
# B — DARK. High contrast; the only dark thing in a WhatsApp feed.
# ══════════════════════════════════════════════════════════════════
B_CSS = """
 body{background:radial-gradient(120% 80% at 20% 0%,#26483A 0%,#16241E 60%,#101A16 100%);color:#fff}
 .top{padding:56px 68px 0;display:flex;align-items:center;gap:26px}
 .top img{width:186px;height:121px;object-fit:cover;border-radius:16px;flex:none;
          box-shadow:0 20px 50px -18px rgba(0,0,0,.75)}
 .wm{font-size:46px;font-weight:800;letter-spacing:-.035em;line-height:1}
 .wm span{color:#8FBFA8}
 .tag{margin-top:9px;font-size:12px;font-weight:700;letter-spacing:.26em;color:#6E8C7C;text-transform:uppercase}
 .hero{padding:0 68px}
 .hero h1{font-size:78px;font-weight:900;letter-spacing:-.045em;line-height:.98}
 .hero h1 em{font-style:normal;color:#E08A6B}
 .hero p{margin-top:26px;font-size:25px;line-height:1.45;color:#A9C3B4;font-weight:500;max-width:860px}
 ul{list-style:none;padding:0 68px;display:grid;grid-template-columns:1fr 1fr;gap:26px 44px}
 li{display:flex;gap:14px;align-items:flex-start}
 li i{font-style:normal;width:26px;height:26px;border-radius:50%;background:rgba(224,138,107,.18);
      color:#E08A6B;font-size:13px;font-weight:800;display:grid;place-items:center;flex:none;margin-top:3px}
 li b{display:block;font-size:20px;font-weight:700;letter-spacing:-.015em;line-height:1.3}
 li span{display:block;font-size:15px;color:#8FA79A;margin-top:2px;font-weight:500}
 .mid{flex:1;display:flex;flex-direction:column;justify-content:space-evenly}
 .price{margin:0 68px;display:flex;align-items:center;justify-content:space-between;
        gap:22px;padding:26px 30px;border:1px solid rgba(255,255,255,.14);border-radius:18px;
        background:rgba(255,255,255,.04)}
 .price .from{font-size:14px;font-weight:700;letter-spacing:.14em;text-transform:uppercase;color:#6E8C7C}
 .price .big{font-size:52px;font-weight:900;letter-spacing:-.04em;line-height:1;margin-top:6px}
 .price .big small{font-size:20px;font-weight:700;color:#8FA79A;letter-spacing:0}
 .price .note{font-size:15px;color:#8FA79A;font-weight:500;text-align:right;line-height:1.5}
 .cta{margin-top:34px;background:#F6F3EC;color:var(--g900);padding:38px 68px;
      display:flex;align-items:center;justify-content:space-between;gap:26px}
 .cta h2{font-size:30px;font-weight:800;letter-spacing:-.025em}
 .cta p{font-size:16px;color:var(--muted);margin-top:6px;font-weight:500}
 .cta .n{font-size:36px;font-weight:900;letter-spacing:-.03em;white-space:nowrap}
 .cta .e{font-size:15px;color:var(--muted);margin-top:5px;font-weight:600;text-align:right}
"""
B_ITEMS = [
    ("Your own branded app", "your name, your logo, your address"),
    ("Fees that price themselves", "every student billed correctly"),
    ("WhatsApp reminders", "on a schedule — and they stop on their own"),
    ("UPI straight to you", "no gateway, no cut"),
    ("Attendance in seconds", "courtside, on a phone"),
    ("Register-only coach logins", "they never see your money"),
]
B_BODY = f"""
 <div class="top"><img src="data:image/jpeg;base64,{MARK}">
  <div><div class="wm">Academy<span>Manager</span></div>
       <div class="tag">Sports · Operations · Insight</div></div></div>
 <div class="mid">
 <div class="hero"><h1>Stop chasing<br><em>fees.</em></h1>
  <p>Your academy's own app — students, attendance, fees and
     WhatsApp reminders, run from your phone.</p></div>
 <ul>{''.join(f'<li><i>✓</i><div><b>{t}</b><span>{s}</span></div></li>' for t,s in B_ITEMS)}</ul>
 </div>
 <div class="price">
   <div><div class="from">Plans from</div>
        <div class="big">₹899<small>/month</small></div></div>
   <div class="note">By academy size — 50 to 150+ students.<br>
        Every plan is the full app. GST extra.</div></div>
 <div class="cta"><div><h2>See it on your own numbers.</h2>
   <p>15 minutes — or ask me for the 2-minute video.</p></div>
   <div><div class="n">99515 97567</div><div class="e">tarun.sujit@gmail.com</div></div></div>
"""

# ══════════════════════════════════════════════════════════════════
# C — POSTER. The logo is the product's best asset; let it breathe.
# ══════════════════════════════════════════════════════════════════
C_CSS = """
 body{background:linear-gradient(180deg,#F8F5EF 0%,#FFFFFF 42%);color:var(--ink);
      align-items:center;text-align:center}
 .pmid{flex:1;display:flex;flex-direction:column;align-items:center;justify-content:space-evenly;padding:54px 0 34px}
 .mark{margin-top:0;width:520px;height:339px;object-fit:cover;border-radius:26px;
       mix-blend-mode:multiply}
 .wm{margin-top:0;font-size:64px;font-weight:800;letter-spacing:-.038em;line-height:1;color:var(--g900)}
 .wm span{color:var(--g500)}
 .tag{margin-top:14px;font-size:14px;font-weight:700;letter-spacing:.3em;color:var(--sage);text-transform:uppercase}
 .line{margin-top:0;font-size:38px;font-weight:700;letter-spacing:-.03em;line-height:1.25;
       color:var(--g900);max-width:900px}
 .line em{font-style:normal;color:var(--terra)}
 .words{margin-top:0;display:flex;gap:0;align-items:center}
 .words b{font-size:19px;font-weight:700;color:var(--g700);letter-spacing:-.01em;padding:0 26px}
 .words i{width:5px;height:5px;border-radius:50%;background:var(--sage);flex:none}
 .from{font-size:19px;font-weight:600;color:var(--muted)}
 .from b{font-size:30px;font-weight:900;color:var(--g900);letter-spacing:-.03em}
 .cta{margin-top:34px;width:100%;background:var(--g900);color:#fff;padding:40px 70px;
      display:flex;align-items:center;justify-content:space-between;text-align:left;gap:26px}
 .cta h2{font-size:29px;font-weight:800;letter-spacing:-.025em}
 .cta p{font-size:16px;color:#A6C2B4;margin-top:6px;font-weight:500}
 .cta .n{font-size:36px;font-weight:900;letter-spacing:-.03em;white-space:nowrap}
 .cta .e{font-size:15px;color:#A6C2B4;margin-top:5px;font-weight:600;text-align:right}
"""
C_BODY = f"""
 <div class="pmid">
 <img class="mark" src="data:image/jpeg;base64,{MARK}">
 <div><div class="wm">Academy<span>Manager</span></div>
      <div class="tag">Sports · Operations · Insight</div></div>
 <div class="line">Your academy's <em>own app</em> —<br>not a login on someone else's.</div>
 <div class="words"><b>Fees</b><i></i><b>Attendance</b><i></i><b>Reminders</b><i></i><b>Bookings</b></div>
 <div class="from">Plans from <b>₹899</b> a month · by academy size</div>
 </div>
 <div class="cta"><div><h2>Have a look?</h2>
   <p>15-minute walkthrough, or a 2-minute video.</p></div>
   <div><div class="n">99515 97567</div><div class="e">tarun.sujit@gmail.com</div></div></div>
"""

# ══════════════════════════════════════════════════════════════════
# D — CONTRAST. Sells the pain first. Owners recognise themselves.
# ══════════════════════════════════════════════════════════════════
D_CSS = """
 body{background:#fff;color:var(--ink)}
 .top{background:linear-gradient(180deg,#F8F5EF,#F1EDE3);padding:38px 62px 32px;
      display:flex;align-items:center;gap:24px;border-bottom:4px solid var(--g700)}
 .top img{width:170px;height:111px;object-fit:cover;border-radius:12px;flex:none;mix-blend-mode:multiply}
 .wm{font-size:43px;font-weight:800;letter-spacing:-.035em;line-height:1;color:var(--g900)}
 .wm span{color:var(--g500)}
 .tag{margin-top:8px;font-size:11.5px;font-weight:700;letter-spacing:.26em;color:var(--sage);text-transform:uppercase}
 h1{padding:0 62px;font-size:50px;font-weight:800;letter-spacing:-.035em;line-height:1.12;color:var(--g900)}
 h1 em{font-style:normal;color:var(--terra)}
 .dmid{flex:1;display:flex;flex-direction:column;justify-content:space-evenly;padding:44px 0 0}
 .cols{display:grid;grid-template-columns:1fr 1fr;gap:20px;padding:0 62px}
 .col{border-radius:18px;padding:30px 26px 32px}
 .col.bad{background:#F7F6F4;border:1px solid #E6E3DD}
 .col.good{background:#F2F8F4;border:2px solid var(--g700)}
 .col h3{font-size:15px;font-weight:800;letter-spacing:.1em;text-transform:uppercase;margin-bottom:18px}
 .col.bad h3{color:#9AA29B}
 .col.good h3{color:var(--g700)}
 .col p{display:flex;gap:12px;align-items:flex-start;font-size:20px;line-height:1.4;
        font-weight:600;padding:15px 0;border-top:1px solid rgba(0,0,0,.06)}
 .col p:first-of-type{border-top:0;padding-top:0}
 .col.bad p{color:#7C837D}
 .col i{font-style:normal;flex:none;width:24px;height:24px;border-radius:50%;font-size:11px;
        font-weight:800;display:grid;place-items:center;margin-top:2px}
 .col.bad i{background:#E2DED7;color:#8E958E}
 .col.good i{background:var(--g700);color:#fff}
 .price{margin:0 62px;text-align:center;padding-top:0}
 .price .p{font-size:20px;color:var(--muted);font-weight:600}
 .price .p b{font-size:33px;font-weight:900;color:var(--g900);letter-spacing:-.03em}
 .cta{margin-top:30px;background:var(--g900);color:#fff;padding:36px 62px;
      display:flex;align-items:center;justify-content:space-between;gap:26px}
 .cta h2{font-size:29px;font-weight:800;letter-spacing:-.025em}
 .cta p{font-size:16px;color:#A6C2B4;margin-top:6px;font-weight:500}
 .cta .n{font-size:35px;font-weight:900;letter-spacing:-.03em;white-space:nowrap}
 .cta .e{font-size:15px;color:#A6C2B4;margin-top:5px;font-weight:600;text-align:right}
"""
D_BAD = ["Fees chased one parent at a time",
         "Attendance in a notebook",
         "\"Who has paid?\" — open the Excel",
         "The coach can see everything",
         "Nobody knows this month's collection"]
D_GOOD = ["Reminders go out on a schedule",
          "Register marked courtside in seconds",
          "Dues and history, always current",
          "Coaches get the register, nothing else",
          "Collections by month and centre"]
D_BODY = f"""
 <div class="top"><img src="data:image/jpeg;base64,{MARK}">
  <div><div class="wm">Academy<span>Manager</span></div>
       <div class="tag">Sports · Operations · Insight</div></div></div>
 <div class="dmid">
 <h1>Running an academy on<br>WhatsApp and Excel? <em>There's an app.</em></h1>
 <div class="cols">
  <div class="col bad"><h3>Right now</h3>
   {''.join(f'<p><i>✕</i>{t}</p>' for t in D_BAD)}</div>
  <div class="col good"><h3>With Academy Manager</h3>
   {''.join(f'<p><i>✓</i>{t}</p>' for t in D_GOOD)}</div></div>
 <div class="price"><div class="p">Your own branded app, from
   <b>₹899</b> a month — by academy size</div></div>
 </div>
 <div class="cta"><div><h2>See it on your own numbers.</h2>
   <p>15 minutes — or ask me for the 2-minute video.</p></div>
   <div><div class="n">99515 97567</div><div class="e">tarun.sujit@gmail.com</div></div></div>
"""

# ══════════════════════════════════════════════════════════════════
# E — MESSAGE. Shows the actual product doing the thing that sells it.
# ══════════════════════════════════════════════════════════════════
E_CSS = """
 body{background:#fff;color:var(--ink)}
 .top{background:linear-gradient(180deg,#F8F5EF,#F1EDE3);padding:36px 62px 30px;
      display:flex;align-items:center;gap:24px;border-bottom:4px solid var(--g700)}
 .top img{width:162px;height:106px;object-fit:cover;border-radius:12px;flex:none;mix-blend-mode:multiply}
 .wm{font-size:41px;font-weight:800;letter-spacing:-.035em;line-height:1;color:var(--g900)}
 .wm span{color:var(--g500)}
 .tag{margin-top:8px;font-size:11px;font-weight:700;letter-spacing:.26em;color:var(--sage);text-transform:uppercase}
 h1{padding:0 62px;font-size:52px;font-weight:800;letter-spacing:-.038em;line-height:1.1;color:var(--g900)}
 h1 em{font-style:normal;color:var(--terra)}
 .sub{padding:18px 62px 0;margin-bottom:6px;font-size:21px;color:var(--muted);font-weight:500;line-height:1.45;max-width:880px}
 .emid{flex:1;display:flex;flex-direction:column;justify-content:space-evenly;padding:38px 0 0}
 .chat{width:660px;margin:0 auto;background:#ECE5DD;border-radius:26px;padding:26px 20px;
       display:flex;flex-direction:column;gap:14px;box-shadow:0 18px 44px -20px rgba(22,36,30,.4)}
 .bub{background:#fff;border-radius:16px 16px 16px 4px;padding:16px 18px;max-width:92%;
      box-shadow:0 2px 5px rgba(0,0,0,.09);font-size:18px;line-height:1.5;font-weight:500}
 .bub.me{align-self:flex-end;background:#DCF8C6;border-radius:16px 16px 4px 16px;max-width:70%}
 .bub b{font-weight:800}
 .bub .amt{display:inline-block;margin-top:9px;font-size:23px;font-weight:900;color:var(--g900);letter-spacing:-.02em}
 .bub .lnk{display:block;margin-top:9px;color:#1B7FD1;font-weight:600;font-size:16.5px}
 .bub .t{display:block;text-align:right;font-size:12px;color:#98A29A;margin-top:6px;font-weight:600}
 .steps{display:flex;gap:0;margin:0 62px;align-items:stretch}
 .st{flex:1;text-align:center;padding:0 12px;position:relative}
 .st b{display:block;font-size:15.5px;font-weight:800;color:var(--g900);letter-spacing:-.01em}
 .st span{display:block;font-size:13.5px;color:var(--muted);margin-top:4px;font-weight:500;line-height:1.35}
 .st:not(:last-child):after{content:"→";position:absolute;right:-9px;top:0;color:var(--sage);font-size:17px}
 .price{margin:0 62px;text-align:center;padding-top:0}
 .price .p{font-size:19px;color:var(--muted);font-weight:600}
 .price .p b{font-size:31px;font-weight:900;color:var(--g900);letter-spacing:-.03em}
 .cta{margin-top:28px;background:var(--g900);color:#fff;padding:34px 62px;
      display:flex;align-items:center;justify-content:space-between;gap:26px}
 .cta h2{font-size:28px;font-weight:800;letter-spacing:-.025em}
 .cta p{font-size:15.5px;color:#A6C2B4;margin-top:6px;font-weight:500}
 .cta .n{font-size:34px;font-weight:900;letter-spacing:-.03em;white-space:nowrap}
 .cta .e{font-size:14.5px;color:#A6C2B4;margin-top:5px;font-weight:600;text-align:right}
"""
E_STEPS = [("Reminder goes out", "2 days before, on the day, then day 5"),
           ("Parent taps", "UPI opens with your account filled in"),
           ("You confirm", "one tap at the desk"),
           ("Everything closes", "dues, renewal and reminder together")]
E_BODY = f"""
 <div class="top"><img src="data:image/jpeg;base64,{MARK}">
  <div><div class="wm">Academy<span>Manager</span></div>
       <div class="tag">Sports · Operations · Insight</div></div></div>
 <div class="emid">
 <h1>This message goes out<br><em>without you.</em></h1>
 <div class="sub">Your academy's own app works out who owes what, and reminds
   the parent politely — until they pay, then it stops.</div>
 <div class="chat">
  <div class="bub">Hi Anitha 👋<br>
   <b>Aarav's</b> August fee for Badminton (Kondapur, 5–6pm) is due on 5 August.
   <span class="amt">₹2,400</span>
   <span class="lnk">Tap to pay by UPI →</span>
   <span class="t">Raj Sports · 9:02 am ✓✓</span></div>
  <div class="bub me">Paid 🙏<br><span class="t">9:14 am</span></div>
 </div>
 <div class="steps">
  {''.join(f'<div class="st"><b>{t}</b><span>{s}</span></div>' for t,s in E_STEPS)}
 </div>
 <div class="price"><div class="p">Your own branded app, from
   <b>₹899</b> a month — by academy size</div></div>
 </div>
 <div class="cta"><div><h2>Want this running for your academy?</h2>
   <p>15-minute walkthrough — or ask me for the 2-minute video.</p></div>
   <div><div class="n">99515 97567</div><div class="e">tarun.sujit@gmail.com</div></div></div>
"""

VARIANTS = {
    "flyer-b-dark":     (B_CSS, B_BODY),
    "flyer-c-poster":   (C_CSS, C_BODY),
    "flyer-d-contrast": (D_CSS, D_BODY),
    "flyer-e-message":  (E_CSS, E_BODY),
}

for name, (css, body) in VARIANTS.items():
    hp = HERE / f"{name}.html"
    pp = HERE / f"{name}.png"
    hp.write_text(shell(css, body))
    subprocess.run([CHROME, "--headless", "--disable-gpu", "--hide-scrollbars",
                    f"--screenshot={pp}", f"--window-size={W},{H}",
                    "--force-device-scale-factor=2", "--virtual-time-budget=6000",
                    f"file://{hp}"], check=True, capture_output=True)
    print(f"✓ {name}.png")
