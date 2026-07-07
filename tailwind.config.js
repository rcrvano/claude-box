/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ['./site/**/*.html', './site/**/*.js'],
  theme: {
    extend: {
      colors: {
        paper: '#F7F8FA', panel: '#FFFFFF', ink: '#0E1116',
        slate: '#5B6573', line: '#E6E9EF',
        iris: '#5B5BD6', 'iris-ink': '#4848C7', coral: '#D97757',
        live: '#16A34A', wait: '#E0A100', stop: '#9AA7B8',
        screen: '#0E1116', 'screen-2': '#171A21',
        'screen-line': '#262B36', 'screen-txt': '#C9CFDA',
      },
      fontFamily: {
        display: ['"Space Grotesk"', 'system-ui', 'sans-serif'],
        sans: ['Inter', 'system-ui', '-apple-system', 'Segoe UI', 'sans-serif'],
        mono: ['"IBM Plex Mono"', 'ui-monospace', 'Menlo', 'Consolas', 'monospace'],
      },
      letterSpacing: { tightest: '-0.035em', tighter: '-0.025em' },
      maxWidth: { content: '1120px' },
      boxShadow: {
        soft: '0 1px 2px rgba(16,17,22,.04)',
        lift: '0 16px 34px -22px rgba(40,44,80,.35)',
        board: '0 30px 60px -28px rgba(40,44,80,.28), 0 2px 6px rgba(16,17,22,.05)',
        window: '0 30px 60px -30px rgba(40,44,80,.45)',
      },
    },
  },
  plugins: [],
}
