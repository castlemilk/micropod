import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        background: "var(--bg)",
        card: "var(--bg-card)",
        secondary: "var(--bg-secondary)",
        foreground: "var(--fg)",
        muted: "var(--fg-muted)",
        border: "var(--border)",
        primary: "var(--primary)",
        success: "var(--success)",
        warn: "var(--warn)",
        destructive: "var(--destructive)",
      },
      fontFamily: {
        sans: ["'Instrument Sans'", "system-ui", "sans-serif"],
        mono: ["'JetBrains Mono'", "ui-monospace", "monospace"],
      },
    },
  },
  plugins: [],
};

export default config;
