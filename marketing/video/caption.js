/* Captions are drawn INSIDE the page, not burned on afterwards: this ffmpeg
   build has no drawtext (no libfreetype), and rendering in the browser gets
   the product's own typeface and a real backdrop blur for free. */
module.exports = function injectCaption(kicker, line) {
  var old = document.getElementById("__cap"); if (old) old.remove();
  var d = document.createElement("div");
  d.id = "__cap";
  d.innerHTML =
    '<div style="font:700 15px/1 Inter,system-ui,sans-serif;letter-spacing:.22em;' +
    'text-transform:uppercase;color:#ffc552;margin-bottom:14px">' + kicker + "</div>" +
    '<div style="font:700 44px/1.18 Outfit,Inter,system-ui,sans-serif;color:#fff;' +
    'max-width:1150px;text-wrap:balance">' + line + "</div>";
  d.style.cssText =
    "position:fixed;left:72px;bottom:64px;z-index:2147483647;padding:30px 38px;" +
    "border-radius:20px;background:rgba(8,10,20,.74);" +
    "-webkit-backdrop-filter:blur(22px) saturate(140%);backdrop-filter:blur(22px) saturate(140%);" +
    "border:1px solid rgba(255,255,255,.14);box-shadow:0 30px 80px rgba(0,0,0,.5);" +
    "opacity:0;transform:translateY(16px);transition:opacity .5s ease,transform .5s ease";
  document.body.appendChild(d);
  requestAnimationFrame(function () { d.style.opacity = "1"; d.style.transform = "translateY(0)"; });
  return true;
};
