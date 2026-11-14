-- =====================================================================
--  BODEGA ATLANTIC · Script 9: rótulos anulados
--  Si se borra un producto mal cargado en el Recibidor, sus rótulos quedan ANULADOS
--  y no se pueden ubicar ni usar.
--  Pégalo en Supabase → SQL Editor → Run. Se puede correr más de una vez.
-- =====================================================================
create or replace function public.bd_ubicar_etiqueta(d jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare e public.etiquetas;
begin
  select * into e from etiquetas where upper(etiqueta_id) = upper(trim(coalesce(d->>'etiquetaId',''))) for update;
  if e.etiqueta_id is null then raise exception 'Identificador no encontrado'; end if;
  if e.estado = 'ANULADA' then raise exception 'El rótulo % fue anulado. No se puede ubicar.', e.etiqueta_id; end if;
  if e.estado = 'SALIDA' then raise exception 'El rótulo % ya salió de la bodega y no se puede volver a usar. Crea un rótulo nuevo.', e.etiqueta_id; end if;
  if e.estado = 'UBICADA' then raise exception 'Este identificador ya se ubicó en %', e.ubicacion_id; end if;
  perform mov_(jsonb_build_object('tipo','ENTRADA','ubicacionId',d->>'ubicacionId','productoId',e.codigo,
     'cantidad', case when e.tipo = 'PESO' then e.total else e.cajas end,
     'unidad', case when e.tipo = 'PESO' then 'UND' else 'CAJA' end,
     'lote',e.etiqueta_id,'vencimiento',e.fecha_vencimiento,'usuario',d->>'usuario','referencia',e.etiqueta_id,
     'observacion','Recibido ' || e.fecha_recibo || ' · Responsable ' || e.responsable
        || case when e.tipo = 'PESO' then ' · Peso variable ' || e.total || ' kg en ' || e.cajas || ' cavas' else '' end));
  update etiquetas set estado = 'UBICADA', ubicacion_id = trim(d->>'ubicacionId'), fecha_ubicacion = now(), ubicado_por = d->>'usuario'
    where etiqueta_id = e.etiqueta_id;
end $$;
revoke all on function public.bd_ubicar_etiqueta(jsonb) from public, anon;
grant execute on function public.bd_ubicar_etiqueta(jsonb) to authenticated;

select 'Listo: rótulos anulados' as resultado;
