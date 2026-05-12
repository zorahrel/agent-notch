import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Build output goes into the SwiftPM resource directory that ships in the
// `.app` bundle (Sources/AgentNotch/Orb/) — the WKWebView in
// NotchController.swift loads `notch.html` from there. Static assets
// (vad/, vendor/, audio/) are preserved via emptyOutDir=false and
// post-processed by scripts/copy-static.mjs.
export default defineConfig({
  plugins: [react()],
  base: "./", // relative paths so file:// or http:// both work
  build: {
    outDir: "../Sources/AgentNotch/Orb",
    emptyOutDir: false, // we keep vad/ + vendor/ + assets/audio/ from old tree
    target: "es2022",
    sourcemap: false,
    rollupOptions: {
      output: {
        // Stable chunk names so the index.html references stay simple.
        entryFileNames: "assets/main-[hash].js",
        chunkFileNames: "assets/chunk-[hash].js",
        assetFileNames: "assets/[name]-[hash][extname]",
      },
    },
  },
  server: {
    proxy: {
      // For local dev: dev server on 5173, router on 3340/3341. SSE + send go to router.
      "/api": "https://localhost:3341",
    },
  },
});
