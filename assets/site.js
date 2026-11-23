// Nagi site: the language switch, the calm (light that comes when the visitor stops, like the
// app), playing only the footage on screen, and a switch that stops all motion.
(() => {
  const root = document.documentElement;
  const reduce = matchMedia("(prefers-reduced-motion: reduce)");
  const loops = [...document.querySelectorAll(".effect video[loop]")];
  const ripples = document.querySelector("#ripples video");
  const play = document.querySelector("#ripples .play");
  const stillButton = document.querySelector(".hush");
  const moving = () => !reduce.matches && !root.classList.contains("still");

  // ---- language: the URL always says which, so a shared link opens in the same language ----
  document.querySelector(".lang").addEventListener("click", () => {
    const lang = root.dataset.lang === "en" ? "ja" : "en";
    root.dataset.lang = lang;
    root.lang = lang;
    try { localStorage.setItem("nagi.lang", lang); } catch (e) {}
    const url = new URL(location.href);
    url.searchParams.set("lang", lang);
    history.replaceState(null, "", url);
  });

  // ---- the calm: 3 s without input brings the light in; any input sends it away ----
  // The fades are in the CSS; the video pauses once the fade out has ended.
  const ONSET = 3000;
  const calm = document.querySelector(".calm");
  const light = calm.querySelector("video");
  const hint = document.querySelector(".hint");
  let timer = 0, stirs = 0;

  function arrive() {
    if (!moving() || document.hidden) return;
    const asked = stirs;
    light.play().then(() => {
      if (asked !== stirs) return;      // input came while the video was starting
      calm.classList.add("on");
      hint?.classList.add("gone");
    }).catch(() => {});
  }
  function stir() {
    stirs++;
    clearTimeout(timer);
    timer = setTimeout(arrive, ONSET);
    calm.classList.remove("on");
  }
  calm.addEventListener("transitionend", () => { if (!calm.classList.contains("on")) light.pause(); });
  for (const type of ["pointermove", "pointerdown", "wheel", "scroll", "keydown", "touchstart"]) {
    addEventListener(type, stir, { passive: true });
  }
  document.addEventListener("visibilitychange", stir);
  stir();

  // ---- footage: play the loop that is mostly on screen, pause the rest ----
  const visible = new Set();
  function refresh() {
    for (const video of loops) {
      if (moving() && visible.has(video)) video.play().catch(() => {});
      else video.pause();
    }
    if (!moving()) { light.pause(); calm.classList.remove("on"); }
  }
  const watcher = new IntersectionObserver((entries) => {
    for (const { target, intersectionRatio } of entries) {
      if (intersectionRatio >= 0.4) visible.add(target); else visible.delete(target);
    }
    refresh();
  }, { threshold: [0, 0.4] });
  loops.forEach((video) => watcher.observe(video));
  reduce.addEventListener("change", refresh);

  // ---- stop all motion, for as long as the visitor wants ----
  stillButton.addEventListener("click", () => {
    const still = root.classList.toggle("still");
    stillButton.setAttribute("aria-pressed", String(still));
    if (still) ripples.pause();
    refresh();
  });

  // ---- ripples never start on their own (photosensitivity); only the button plays and stops them ----
  play.addEventListener("click", () => {
    if (ripples.paused) {
      if (ripples.ended) ripples.currentTime = 0;
      ripples.play().catch(() => {});
    } else {
      ripples.pause();
    }
  });
  const pressed = () => play.setAttribute("aria-pressed", String(!ripples.paused));
  ripples.addEventListener("play", pressed);
  ripples.addEventListener("pause", pressed);
})();
