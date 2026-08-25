/* Shown to international prospects, so three things in the demo data have to
   go: the rupee symbol, the Indian city/locality branding, and the word
   WhatsApp (the user's brief: markets like the UAE get "alerts to parents"
   instead of a named channel).

   The currency is a SYMBOL swap with the figures left alone, deliberately.
   Converting ₹52,380 to AED would read ~AED 2,300 for 94 members, which is
   implausibly cheap for Dubai; left as AED 52,380 it works out at about
   AED 557 per member per month, which is squarely in-market. The data is
   fictitious either way, so the only thing that matters is that it is
   believable to the person watching. */
module.exports = function localiseSource() {
  var MAP = [
    [/₹/g, "AED "],
    [/\bBENGALURU\b/g, "DUBAI"], [/\bBengaluru\b/g, "Dubai"],
    [/\bHYDERABAD\b/g, "DUBAI"],  [/\bHyderabad\b/g, "Dubai"],
    [/\bIndiranagar\b/g, "Al Quoz"], [/\bYelahanka\b/g, "Dubai Sports City"],
    [/\bKompally\b/g, "Al Quoz"], [/\bMiyapur\b/g, "Jumeirah"],
    [/\bLingampally\b/gi, "Al Barsha"],
    [/WhatsApp/g, "Parent alerts"], [/whatsapp/g, "alerts"],
    [/\+91[\s-]?/g, "+971 "], [/\b91 80\b/g, "971 4"],
    [/\bIndia\b/g, "UAE"]
  ];
  function fix(s) { MAP.forEach(function (m) { s = s.replace(m[0], m[1]); }); return s; }

  var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  var nodes = [], n;
  while ((n = walker.nextNode())) nodes.push(n);
  nodes.forEach(function (t) {
    if (t.parentNode && /^(SCRIPT|STYLE)$/.test(t.parentNode.nodeName)) return;
    var v = fix(t.nodeValue);
    if (v !== t.nodeValue) t.nodeValue = v;
  });
  // placeholders and titles are not text nodes
  document.querySelectorAll("[placeholder]").forEach(function (el) {
    el.setAttribute("placeholder", fix(el.getAttribute("placeholder")));
  });
  document.title = fix(document.title);
  return true;
};
