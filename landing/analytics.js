(function (root) {
  "use strict";
  const KEY = "micropod-website-analytics-v1";
  const PAGES = { "/micropod/": "Home", "/micropod/index.html": "Home" };
  function eligible(config, location, navigator) {
    return config && config.enabled === true && config.gaPrivacyReviewed === true &&
      /^G-[A-Z0-9]+$/.test(config.gaMeasurementId || "") &&
      /^https:\/\/[^/?#]+$/.test(config.origin || "") && location.origin === config.origin &&
      Object.hasOwn(PAGES, location.pathname) && !location.search && !location.hash &&
      navigator.doNotTrack !== "1" && navigator.globalPrivacyControl !== true;
  }
  function boot(win, doc, config) {
    if (!eligible(config, win.location, win.navigator) || doc.getElementById("micropod-analytics-choice")) return;
    let choice = "denied";
    try { choice = win.sessionStorage.getItem(KEY) || "denied"; } catch { return; }
    const panel = doc.createElement("section");
    panel.id = "micropod-analytics-choice";
    panel.className = "analytics-choice";
    panel.setAttribute("aria-label", "Optional website analytics");
    const description = doc.createElement("p");
    description.textContent = "Optional website analytics: Google Analytics can measure visits and download-button clicks using cookies and browser/network information. No container, volume, network or file inventory is shared. Your choice lasts for this tab. You can turn it off here.";
    const accept = doc.createElement("button");
    accept.type = "button"; accept.className = "btn-secondary"; accept.textContent = "Allow website analytics";
    const decline = doc.createElement("button");
    decline.type = "button"; decline.className = "btn-secondary"; decline.textContent = "Keep analytics off";
    const status = doc.createElement("p");
    status.setAttribute("role", "status");
    panel.append(description, accept, decline, status);
    doc.body.append(panel);
    let loaded = false;
    function render() {
      status.textContent = choice === "granted" ? "Analytics allowed for this tab." : "Analytics are off.";
      accept.disabled = choice === "granted";
      decline.textContent = choice === "granted" ? "Turn analytics off" : "Keep analytics off";
    }
    function start() {
      if (loaded || choice !== "granted" || !eligible(config, win.location, win.navigator)) return;
      loaded = true;
      win["ga-disable-" + config.gaMeasurementId] = false;
      win.dataLayer = win.dataLayer || [];
      function gtag() { win.dataLayer.push(arguments); }
      win.gtag = gtag;
      const safeLocation = config.origin + ("/micropod/");
      gtag("consent", "default", { analytics_storage: "granted", ad_storage: "denied", ad_user_data: "denied", ad_personalization: "denied" });
      gtag("js", new Date());
      gtag("config", config.gaMeasurementId, { send_page_view: false, allow_google_signals: false,
        allow_ad_personalization_signals: false, cookie_prefix: "micropod", cookie_path: "/micropod/", cookie_domain: "none", page_location: safeLocation, page_referrer: "", page_title: "Micropod " + PAGES[win.location.pathname] });
      gtag("event", "page_view", { send_to: config.gaMeasurementId });
      const script = doc.createElement("script");
      script.id = "micropod-ga-script"; script.async = true; script.referrerPolicy = "no-referrer";
      script.src = "https://www.googletagmanager.com/gtag/js?id=" + config.gaMeasurementId;
      doc.head.append(script);
    }
    accept.addEventListener("click", () => {
      try { win.sessionStorage.setItem(KEY, "granted"); } catch { return; }
      choice = "granted"; render(); start();
    });
    decline.addEventListener("click", () => {
      // Deny before any reload, including when the async vendor script is still pending.
      win["ga-disable-" + config.gaMeasurementId] = true;
      win.dataLayer = [];
      let persisted = false;
      try { win.sessionStorage.setItem(KEY, "denied"); persisted = true; }
      catch { try { win.sessionStorage.removeItem(KEY); persisted = true; } catch { /* Never reload into a stale grant. */ } }
      choice = "denied"; render();
      if (!persisted) status.textContent = "Analytics are off on this page. Browser storage is unavailable; close this tab to discard its previous choice.";
      if (loaded && persisted) win.location.reload();
    });
    // Only a fixed download-intent event, never text, target URL or form content.
    doc.addEventListener("click", (event) => {
      if (!loaded || choice !== "granted" || win["ga-disable-" + config.gaMeasurementId]) return;
      const link = event.target.closest && event.target.closest('a[data-analytics="download"]');
      if (link) win.gtag("event", "download_intent", { send_to: config.gaMeasurementId, asset: "mac_dmg" });
    });
    render(); start();
  }
  if (typeof module !== "undefined" && module.exports) module.exports = { eligible, boot };
  else boot(root, root.document, root.MICROPOD_ANALYTICS);
})(typeof window === "undefined" ? globalThis : window);
