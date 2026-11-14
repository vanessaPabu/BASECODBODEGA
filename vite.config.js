import { defineConfig } from 'vite';

export default defineConfig({
  // Rutas relativas: la app funciona en cualquier dirección
  // (Netlify, GitHub Pages en usuario.github.io/bodega/, o el servidor de AWS)
  base: './',
  server: { host: true },  // permite abrir la app desde el celular en la misma red wifi
  // Número de versión de cada "npm run build": hace que el navegador traiga siempre el cliente.js nuevo
  define: { __VERSION__: JSON.stringify(Date.now().toString(36)) }
});