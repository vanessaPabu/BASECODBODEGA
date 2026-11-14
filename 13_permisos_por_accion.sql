-- =====================================================================
--  BODEGA ATLANTIC · Script 13: permisos por acción dentro de cada módulo
--   Recibir mercancía: crear facturas · cargar lo que debe llegar · recibir producto
--                      · corregir lo recibido · fotos · cerrar facturas
--   Calidad: ver · fotos y links · descargar Excel
--   Inventario del recibo: ver · descargar Excel
--  Los Jefes quedan con todos. Los demás conservan lo que tenían y,
--  si podían recibir, también pueden tomar fotos.
--  Pégalo en Supabase → SQL Editor → Run (después del 12). Se puede correr más de una vez.
-- =====================================================================

create or replace function public.seg_permisos_validos(p text[]) returns text[]
language sql immutable as $$
  select coalesce(array_agg(distinct x order by x), '{}') from unnest(p) x
  where x = any (array[
    'ubicar','mover','salida','estructura',
    'productos','reportes',
    'rotular',
    'rc_facturas','rc_lista','recibir','rc_corregir','rc_fotos','rc_cerrar',
    'calidad','cal_editar','cal_excel',
    'inv_recibo','inv_excel',
    'config','usuarios'])
$$;

-- Jefes: todos los permisos
update public.operarios set permisos = public.seg_permisos_validos(permisos || array[
  'ubicar','mover','salida','estructura','productos','reportes','rotular',
  'rc_facturas','rc_lista','recibir','rc_corregir','rc_fotos','rc_cerrar',
  'calidad','cal_editar','cal_excel','inv_recibo','inv_excel','config'])
where rol = 'JEFE';

-- Los demás: lo equivalente a lo que ya tenían
update public.operarios set permisos = public.seg_permisos_validos(permisos || array['rc_fotos'])
  where rol <> 'JEFE' and 'recibir' = any (permisos);
update public.operarios set permisos = public.seg_permisos_validos(permisos || array['cal_editar'])
  where rol <> 'JEFE' and 'calidad' = any (permisos);
update public.operarios set permisos = public.seg_permisos_validos(permisos || array['cal_excel'])
  where rol <> 'JEFE' and 'calidad' = any (permisos) and 'reportes' = any (permisos);
update public.operarios set permisos = public.seg_permisos_validos(permisos || array['inv_excel'])
  where rol <> 'JEFE' and 'inv_recibo' = any (permisos) and 'reportes' = any (permisos);

select 'Listo: permisos por acción' as resultado;
