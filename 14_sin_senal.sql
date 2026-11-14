-- =====================================================================
--  BODEGA ATLANTIC · Script 14: trabajar sin señal
--  Cuando un equipo pierde la señal justo mientras envía algo, al volver la señal lo
--  envía otra vez. Con esto el servidor reconoce que ya lo tenía y no lo hace dos veces:
--   - Mover: cada traslado lleva su número (movimientoId)
--   - Ubicar un rótulo: si ya quedó en ese mismo lugar, no da error
--  (La salida ya venía protegida desde el script 2.)
--  Pégalo en Supabase → SQL Editor → Run. Se puede correr más de una vez.
-- =====================================================================

create index if not exists movimientos_referencia on public.movimientos (referencia_id);

create or replace function public.bd_mover(d jsonb) returns void
language plpgsql set search_path = public as $$
declare
  v_origen  text := trim(coalesce(d->>'origenId',''));
  v_destino text := trim(coalesce(d->>'destinoId',''));
  v_lote    text := trim(coalesce(d->>'lote',''));
  v_id      text := nullif(trim(coalesce(d->>'movimientoId','')), '');
  l         public.inventario;
  v_ref     text;
  comun     jsonb;
begin
  -- Ya se había hecho (llegó dos veces al recuperar la señal): no se repite
  if v_id is not null and exists (select 1 from movimientos where referencia_id = v_id) then
    return;
  end if;
  v_ref := coalesce(v_id, 'TRA-' || to_char(now(), 'YYMMDDHH24MISS') || '-' || floor(random() * 1000));

  if v_destino = '' then raise exception 'Elige el espacio de destino'; end if;
  if v_origen = v_destino then raise exception 'El destino es el mismo espacio de origen'; end if;
  select * into l from inventario where ubicacion_id = v_origen and producto_id = trim(coalesce(d->>'productoId','')) and lote = v_lote;
  if l.inventario_id is null then raise exception 'Ese producto ya no está en el espacio de origen'; end if;

  comun := jsonb_build_object('productoId', d->>'productoId', 'cantidad', d->>'cantidad', 'unidad', d->>'unidad',
             'lote', v_lote, 'vencimiento', l.fecha_vencimiento, 'usuario', d->>'usuario', 'referencia', v_ref);
  perform mov_(comun || jsonb_build_object('tipo','SALIDA','ubicacionId',v_origen,'tipoRegistro','TRASLADO-SALIDA','observacion','Movido a ' || v_destino));
  perform mov_(comun || jsonb_build_object('tipo','ENTRADA','ubicacionId',v_destino,'tipoRegistro','TRASLADO-ENTRADA','observacion','Movido desde ' || v_origen));

  if not exists (select 1 from inventario where ubicacion_id = v_origen and lote = v_lote and cantidad_unidades > 0) then
    update etiquetas set ubicacion_id = v_destino where upper(etiqueta_id) = upper(v_lote);
  end if;
end $$;

create or replace function public.bd_ubicar_etiqueta(d jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare e public.etiquetas;
begin
  select * into e from etiquetas where upper(etiqueta_id) = upper(trim(coalesce(d->>'etiquetaId',''))) for update;
  if e.etiqueta_id is null then raise exception 'Identificador no encontrado'; end if;
  if e.estado = 'ANULADA' then raise exception 'El rótulo % fue anulado. No se puede ubicar.', e.etiqueta_id; end if;
  if e.estado = 'SALIDA' then raise exception 'El rótulo % ya salió de la bodega y no se puede volver a usar. Crea un rótulo nuevo.', e.etiqueta_id; end if;
  if e.estado = 'UBICADA' then
    -- Ya quedó en ese mismo lugar (llegó dos veces): no es error
    if upper(e.ubicacion_id) = upper(trim(coalesce(d->>'ubicacionId',''))) then return; end if;
    raise exception 'Este identificador ya se ubicó en %', e.ubicacion_id;
  end if;
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

select 'Listo: sin señal' as resultado;
