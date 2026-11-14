import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// En Docker Desktop (Windows/macOS) los cambios en carpetas montadas no generan
// eventos del sistema de archivos; con WATCH_POLLING=true Vite los revisa por sondeo.
const polling = process.env.WATCH_POLLING === 'true'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    watch: polling ? { usePolling: true, interval: 300 } : undefined,
  },
})
