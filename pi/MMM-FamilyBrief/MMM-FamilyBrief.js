/* MMM-FamilyBrief
 *
 * The 25% band above the calendar on the fridge wall: the morning brief on the
 * left, the to-do columns on the right.
 *
 * DATA: fetches `dataUrl` every `updateInterval`. If that fails it keeps showing
 * the last good payload rather than blanking -- a wall display that goes empty
 * is worse than one that is a few hours stale. With no `dataUrl` set it renders
 * `mock`, which is how the layout was built before the server side existed.
 *
 * PRIVACY: this panel is read by anyone standing in the kitchen. The generator
 * is responsible for sending only household-level content; this module renders
 * whatever it is given and makes no judgement.
 */
Module.register("MMM-FamilyBrief", {
  defaults: {
    dataUrl: null,
    updateInterval: 15 * 60 * 1000,
    mock: null,
    // Owner key -> colour. Matches the calendar feed colours so the whole wall
    // reads as one system. `family` is the bot's own colour: deliberately not
    // blue or pink, so bot-created items are obvious from across the room.
    colors: {
      jacob:  "#3b82f6",
      cassie: "#ec4899",
      family: "#f59e0b"
    },
    maxItemsPerList: 4
  },

  start () {
    this.data_ = this.config.mock || null;
    this.stale = false;
    if (this.config.dataUrl) {
      this.fetchData();
      setInterval(() => this.fetchData(), this.config.updateInterval);
    }
  },

  getStyles () {
    return [this.file("MMM-FamilyBrief.css")];
  },

  fetchData () {
    fetch(this.config.dataUrl, { cache: "no-store" })
      .then((r) => {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .then((json) => {
        this.data_ = json;
        this.stale = false;
        this.updateDom(0);
      })
      .catch((err) => {
        // Keep the last good payload on screen; just mark it stale.
        Log.warn("MMM-FamilyBrief fetch failed: " + err.message);
        if (this.data_) {
          this.stale = true;
          this.updateDom(0);
        }
      });
  },

  // --- weather icons --------------------------------------------------------

  /* Drawn inline rather than loaded, for three reasons: the Pi renders this
   * with no network guarantee, an <img> that 404s leaves a broken-image box on
   * a kitchen wall, and SVG scales cleanly at the vh sizes this panel uses.
   *
   * The shapes follow the phone's weather strip -- a solid cloud, a sun disc
   * with short rays, a blue droplet -- but recoloured for a WHITE ground: the
   * phone draws light-on-dark, this panel is dark-on-light.
   *
   * Keys are the vocabulary in brief/weather.py. A provider swap changes which
   * keys arrive, never what they mean.
   */
  WX: {
    sun:    "#fbbc04",
    moon:   "#9aa0a6",
    cloud:  "#9aa0a6",
    cloudD: "#5f6368",
    drop:   "#4285f4",
    snow:   "#80868b",
    bolt:   "#fbbc04"
  },

  wxIcon (key) {
    const C = this.WX;
    const NS = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(NS, "svg");
    svg.setAttribute("viewBox", "0 0 48 48");
    svg.setAttribute("class", "FB-wx-icon");

    const add = (tag, attrs) => {
      const n = document.createElementNS(NS, tag);
      Object.entries(attrs).forEach(([k, v]) => n.setAttribute(k, v));
      svg.appendChild(n);
      return n;
    };
    // One cloud silhouette, reused. Three overlapping circles plus a base bar
    // read as Google's puffy cloud at 40px and stay clean at 120px.
    const cloud = (fill, dx, dy, s) => {
      const g = document.createElementNS(NS, "g");
      g.setAttribute("fill", fill);
      g.setAttribute("transform",
        `translate(${dx},${dy}) scale(${s})`);
      [[17, 26, 9], [28, 24, 11], [36, 28, 7]].forEach(([cx, cy, r]) => {
        const c = document.createElementNS(NS, "circle");
        c.setAttribute("cx", cx); c.setAttribute("cy", cy); c.setAttribute("r", r);
        g.appendChild(c);
      });
      const bar = document.createElementNS(NS, "rect");
      bar.setAttribute("x", 8); bar.setAttribute("y", 26);
      bar.setAttribute("width", 35); bar.setAttribute("height", 9);
      bar.setAttribute("rx", 4.5);
      g.appendChild(bar);
      svg.appendChild(g);
      return g;
    };
    const sun = (cx, cy, r, fill) => {
      add("circle", { cx, cy, r, fill });
      for (let i = 0; i < 8; i++) {
        const a = (Math.PI / 4) * i;
        add("line", {
          x1: cx + Math.cos(a) * (r + 2.5), y1: cy + Math.sin(a) * (r + 2.5),
          x2: cx + Math.cos(a) * (r + 6),   y2: cy + Math.sin(a) * (r + 6),
          stroke: fill, "stroke-width": 2.6, "stroke-linecap": "round"
        });
      }
    };
    const drops = (xs, y) => xs.forEach((x) => add("path", {
      d: `M ${x} ${y} c 3.2 4.2 4.8 6.4 4.8 8.2 a 4.8 4.8 0 0 1 -9.6 0 c 0 -1.8 1.6 -4 4.8 -8.2 z`,
      fill: C.drop
    }));
    const flakes = (xs, y) => xs.forEach((x) => add("circle",
      { cx: x, cy: y + 5, r: 2.4, fill: C.snow }));

    switch (key) {
      case "sunny":
        sun(24, 24, 10, C.sun);
        break;
      case "clear-night":
        // A crescent, cut by a second disc rather than drawn as an arc.
        add("path", {
          d: "M 31 12 a 13 13 0 1 0 6 12.5 a 10.5 10.5 0 0 1 -6 -12.5 z",
          fill: C.moon
        });
        break;
      case "partly-cloudy":
        sun(31, 17, 7.5, C.sun);
        cloud(C.cloud, -2, 2, 0.92);
        break;
      case "partly-cloudy-night":
        add("path", {
          d: "M 36 10 a 9 9 0 1 0 4.2 8.7 a 7.3 7.3 0 0 1 -4.2 -8.7 z",
          fill: C.moon
        });
        cloud(C.cloud, -2, 2, 0.92);
        break;
      case "cloudy":
        cloud(C.cloud, 0, 6, 0.78);
        cloud(C.cloudD, 0, 0, 1);
        break;
      case "showers":
        cloud(C.cloudD, 0, -5, 0.92);
        drops([15, 27], 32);
        break;
      case "rain":
        cloud(C.cloudD, 0, -6, 0.92);
        drops([12, 22, 32], 31);
        break;
      case "thunderstorm":
        cloud(C.cloudD, 0, -6, 0.92);
        add("path", { d: "M 25 30 l -7 10 h 5 l -3 8 l 10 -12 h -5 l 4 -6 z",
                      fill: C.bolt });
        break;
      case "snow":
        cloud(C.cloudD, 0, -5, 0.92);
        flakes([14, 24, 34], 32);
        break;
      case "sleet":
        cloud(C.cloudD, 0, -5, 0.92);
        drops([14], 32);
        flakes([30], 32);
        break;
      case "hail":
        cloud(C.cloudD, 0, -5, 0.92);
        flakes([14, 24, 34], 33);
        break;
      case "fog":
        cloud(C.cloud, 0, -7, 0.88);
        [0, 1, 2].forEach((i) => add("rect", {
          x: 9 + (i % 2) * 2, y: 33 + i * 5, width: 30, height: 3, rx: 1.5,
          fill: C.cloud, opacity: 0.85 - i * 0.18
        }));
        break;
      case "windy":
        [[10, 18, 26], [10, 26, 32], [10, 34, 22]].forEach(([x, y, w]) => add("path", {
          d: `M ${x} ${y} h ${w} a 4.5 4.5 0 1 0 -4.5 -4.5`,
          fill: "none", stroke: C.cloud, "stroke-width": 3.2,
          "stroke-linecap": "round"
        }));
        break;
      default:
        cloud(C.cloud, 0, 0, 1);
    }
    return svg;
  },

  wxStrip (wx) {
    const hours = (wx && wx.hours) || [];
    if (!hours.length) return null;
    const strip = this.el("div", "FB-wx");
    hours.forEach((h) => {
      const col = this.el("div", "FB-wx-hour");
      col.appendChild(this.el("div", "FB-wx-label", h.label || ""));
      col.appendChild(this.wxIcon(h.icon));
      // Absent rather than zero: today's provider cannot report a chance of
      // rain, so the row is omitted instead of showing a made-up 0%.
      if (h.precip_pct !== null && h.precip_pct !== undefined) {
        col.appendChild(this.el("div", "FB-wx-pop", h.precip_pct + "%"));
      }
      if (h.temp !== null && h.temp !== undefined) {
        col.appendChild(this.el("div", "FB-wx-temp", h.temp + "\u00b0"));
      }
      strip.appendChild(col);
    });
    return strip;
  },

  // --- rendering ------------------------------------------------------------

  el (tag, cls, text) {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined) n.textContent = text;
    return n;
  },

  getDom () {
    const root = this.el("div", "FB");
    const d = this.data_;

    if (!d) {
      root.appendChild(this.el("div", "FB-empty", "Waiting for the morning brief…"));
      return root;
    }

    // Left: the date and the brief itself.
    const left = this.el("div", "FB-brief");
    const now = new Date();
    left.appendChild(this.el("div", "FB-date",
      now.toLocaleDateString("en-US",
        { weekday: "long", month: "long", day: "numeric" })));

    if (d.headline) left.appendChild(this.el("div", "FB-headline", d.headline));

    // Under the summary, above the day's lines: the weather is context for the
    // sentence above it, not another item in the list below.
    const strip = this.wxStrip(d.weather);
    if (strip) left.appendChild(strip);

    if (Array.isArray(d.lines) && d.lines.length) {
      const ul = this.el("ul", "FB-lines");
      // Three is what fits under a two-line headline. Measured, not guessed.
      d.lines.slice(0, 3).forEach((line) => {
        const li = this.el("li");
        // A line may be a plain string, or {owner, text} to colour its marker.
        if (typeof line === "string") {
          li.textContent = line;
        } else {
          const dot = this.el("span", "FB-dot");
          dot.style.background = this.config.colors[line.owner] || "#9aa0a6";
          li.appendChild(dot);
          li.appendChild(document.createTextNode(line.text));
        }
        ul.appendChild(li);
      });
      left.appendChild(ul);
    }
    root.appendChild(left);

    // Right: one column per to-do list.
    const lists = this.el("div", "FB-lists");
    (d.todos || []).forEach((list) => {
      const col = this.el("div", "FB-list");
      const color = this.config.colors[list.owner] || "#9aa0a6";

      const head = this.el("div", "FB-list-head");
      const dot = this.el("span", "FB-dot");
      dot.style.background = color;
      head.appendChild(dot);
      head.appendChild(this.el("span", "FB-list-name", list.name));
      // The bot's list is labelled so nobody mistakes a machine guess for a
      // decision somebody actually made.
      if (list.auto) head.appendChild(this.el("span", "FB-badge", "auto"));
      col.appendChild(head);

      const items = (list.items || []).slice(0, this.config.maxItemsPerList);
      if (!items.length) {
        col.appendChild(this.el("div", "FB-clear", "All clear"));
      } else {
        const ul = this.el("ul", "FB-items");
        items.forEach((it) => {
          const text = typeof it === "string" ? it : it.text;
          const due  = typeof it === "string" ? null : it.due;
          const li = this.el("li");
          li.appendChild(this.el("span", "FB-item-text", text));
          if (due) li.appendChild(this.el("span", "FB-due", due));
          ul.appendChild(li);
        });
        col.appendChild(ul);

        // `total` is the generator's count BEFORE it trimmed to what fits;
        // list.items has already been cut to that size, so measuring it here
        // always gave 0 and the "+N more" note never once appeared.
        const total = typeof list.total === "number" ? list.total : items.length;
        const extra = total - items.length;
        if (extra > 0) col.appendChild(this.el("div", "FB-more", "+" + extra + " more"));
      }
      lists.appendChild(col);
    });
    root.appendChild(lists);

    if (this.stale) root.appendChild(this.el("div", "FB-stale", "offline"));
    return root;
  }
});
