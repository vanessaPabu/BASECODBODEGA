# Bodega Atlantic

Es la misma app de Apps Script (mismas pantallas y funciones), pero guardando en Supabase en vez de Google Sheets.

## Archivos
- `index.html` — estilos y estructura de la página (igual que el Index.html original)
- `public/cliente.js` — todas las pantallas (es el script del Index.html original; solo cambió la función `llamar`)
- `src/servidor.js` — las funciones bd… (antes App.gs), ahora leen y escriben en Supabase. Aquí está el plano de cada sede.
- `src/main.js` — activa el equipo con la cuenta de la bodega y arranca la app
- `supabase/02_como_la_original.sql` — tablas y funciones de la base de datos (correr en Supabase → SQL Editor)

## Correr en tu PC
```
npm install
npm run dev
```
Necesita el archivo `.env` con la URL y la clave de Supabase (ver `.env.example`).

## Equivalencias con la hoja de cálculo
| Pestaña original | Tabla en Supabase |
|---|---|
| Sedes | sedes |
| Operarios | operarios |
| Espacios | espacios |
| Productos | productos |
| Inventario | inventario |
| Movimientos | movimientos |
| Etiquetas | etiquetas |
| Propiedades CFG_ (zonas y racks cambiados) | sede_config |
