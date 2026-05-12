# agent-notch web client

React + Vite source for the orb HUD that the WKWebView in
`Sources/AgentNotch/NotchController.swift` loads at runtime.

```
web/                               ← you are here
├── src/
│   ├── App.tsx                    ← notch React shell, replicates legacy
│   │                                notch.html DOM verbatim so all the
│   │                                original CSS works unchanged
│   ├── main.tsx                   ← createRoot, mount point
│   ├── store.ts                   ← zustand store (chat log, prefs, timers)
│   ├── components/                ← Bubble, ChatLog, InputRow, ActivityPane,
│   │                                AudioPlayer, LivePartial, TimingStrip,
│   │                                Toolbar
│   ├── hooks/                     ← useSSE (router event stream),
│   │                                useSwiftBridge (WKWebView → Swift),
│   │                                useExternalAssets (lazy-loads
│   │                                Three.js orb, VAD worker, audio-aura)
│   ├── footer.ts                  ← timing footer formatter
│   ├── styles.css                 ← legacy CSS, preserved as-is
│   └── types.ts                   ← shared TypeScript types
├── scripts/copy-static.mjs        ← post-build: index.html → notch.html
├── vite.config.ts
├── tsconfig.json
└── package.json
```

## What this builds

- Output: `../Sources/AgentNotch/Orb/`
  - `notch.html` — the entry the WKWebView loads (renamed from `index.html`
    by the post-build script)
  - `assets/main-<hash>.js` — React bundle (~210 kB minified)
  - `assets/index-<hash>.css` — compiled stylesheet
  - `assets/<font/img/etc>` — additional bundled assets
- `emptyOutDir=false` in `vite.config.ts` preserves these out-of-tree
  static assets that ship with the orb but are NOT processed by Vite:
  - `Sources/AgentNotch/Orb/vad/` — Silero VAD model + WASM runtime
  - `Sources/AgentNotch/Orb/vendor/gsap/` — GSAP physics bundles
  - `Sources/AgentNotch/Orb/assets/{notch-*,audio-aura,three.module,three,space-bg,*woff}.{js,css,jpg,woff}`
    — Three.js orb bundle and friends, loaded at runtime by
    `useExternalAssets.ts`

## Build

```bash
cd web
pnpm install        # or: npm ci
pnpm run build      # or: npm run build
```

After every change you ship to the orb UI you must:
1. Run `pnpm run build` here
2. Commit BOTH the source changes AND the regenerated bundle in
   `../Sources/AgentNotch/Orb/`. SwiftPM treats it as a resource bundle,
   so the `.js`/`.css`/`.html` files MUST be in git for the macOS `.app`
   to ship them.
3. The hash in `main-<hash>.js` / `index-<hash>.css` changes — delete
   the previous-hash orphans in `assets/` (Vite leaves them because
   `emptyOutDir=false`).

## Dev (hot-reload, no Swift rebuild)

```bash
pnpm run dev        # vite dev server on http://localhost:5173
```

Point your browser at it for live HMR. The dev server proxies `/api/*`
to `https://localhost:3341` (the Jarvis router HTTPS port) so SSE +
`/api/notch/*` calls work as in the real app. WKWebView integration
(speech, native bridges) can't be tested in the browser — for that,
build and reload the `.app`.

## Why the source isn't in `Sources/AgentNotch/`

The Swift SwiftPM target only ships the BUILT artifacts (`Orb/notch.html`
+ `Orb/assets/*`) as a resource bundle. The TSX/Vite project lives
alongside as a sibling `web/` directory so:

- `swift build` doesn't try to compile TypeScript files
- `npm install` doesn't pollute the SwiftPM build cache
- The web project can have its own lockfile, gitignore, and CI without
  conflicting with the Swift side

This mirrors the Tauri / Electron convention of separating the web
front-end from the native shell, and is the same layout `jarvis-router`
uses for its `dashboard/` directory.
