-- =====================================================================
--  BODEGA ATLANTIC · Script 3: rotación (primero lo que vence primero)
--  Agrega a Movimientos si una salida se hizo fuera de rotación y el motivo.
--  Pégalo en Supabase → SQL Editor → Run. Se puede correr más de una vez.
-- =====================================================================
alter table public.movimientos add column if not exists fuera_rotacion boolean not null default false;
alter table public.movimientos add column if not exists motivo text;
create index if not exists movimientos_producto on public.movimientos (producto_id, fecha);
create index if not exists movimientos_tipo on public.movimientos (tipo, fecha);

-- Igual que antes, y además guarda fuera_rotacion y motivo. La hora es exacta para que el orden del historial sea el real.
create or replace function public.mov_(d jsonb) returns void
language plpgsql set search_path = public as $$
declare
  v_tipo      text    := upper(trim(coalesce(d->>'tipo','')));
  v_cantidad  numeric := nullif(d->>'cantidad','')::numeric;
  v_ubic      text    := trim(coalesce(d->>'ubicacionId',''));
  v_lote      text    := trim(coalesce(d->>'lote',''));
  v_venc      date    := nullif(trim(coalesce(d->>'vencimiento','')),'')::date;
  p           public.productos;
  v_factor    numeric;
  v_unidades  numeric;
  l           public.inventario;
  v_resto     numeric;
begin
  if v_tipo not in ('ENTRADA','SALIDA') then raise exception 'Tipo de movimiento no válido'; end if;
  if v_cantidad is null or v_cantidad <= 0 then raise exception 'La cantidad debe ser mayor que 0'; end if;
  if not exists (select 1 from espacios where espacio_id = v_ubic and activo) then raise exception 'Ubicación no válida'; end if;
  select * into p from productos where codigo_afs = trim(coalesce(d->>'productoId',''));
  if p.codigo_afs is null then raise exception 'Producto no encontrado'; end if;

  v_factor := case upper(coalesce(d->>'unidad',''))
                when 'UND' then 1 when 'CAJA' then p.und_x_caja
                when 'ESTIBA' then p.und_x_caja * p.cajas_por_estiba end;
  if v_factor is null then raise exception 'Unidad no válida'; end if;
  v_unidades := v_cantidad * v_factor;

  select * into l from inventario where ubicacion_id = v_ubic and producto_id = p.codigo_afs and lote = v_lote for update;

  if v_tipo = 'ENTRADA' then
    if l.inventario_id is not null then
      update inventario set cantidad_unidades = cantidad_unidades + v_unidades, fecha_actualizacion = now()
        where inventario_id = l.inventario_id;
      v_venc := coalesce(l.fecha_vencimiento, v_venc);
    else
      insert into inventario (ubicacion_id, producto_id, lote, fecha_vencimiento, cantidad_unidades)
      values (v_ubic, p.codigo_afs, v_lote, v_venc, v_unidades);
    end if;
  else
    if v_unidades > coalesce(l.cantidad_unidades, 0) then
      raise exception 'Solo hay % unidades de ese producto/lote en esta ubicación', coalesce(l.cantidad_unidades, 0);
    end if;
    v_venc := l.fecha_vencimiento;
    v_resto := l.cantidad_unidades - v_unidades;
    if v_resto = 0 then delete from inventario where inventario_id = l.inventario_id;
    else update inventario set cantidad_unidades = v_resto, fecha_actualizacion = now() where inventario_id = l.inventario_id;
    end if;
  end if;

  insert into movimientos (movimiento_id, fecha, tipo, ubicacion_id, producto_id, lote, fecha_vencimiento, cantidad,
                           unidad_medida, cantidad_unidades, usuario, referencia_id, observacion, fuera_rotacion, motivo)
  values (coalesce(nullif(d->>'movimientoId',''), 'MOV-' || gen_random_uuid()), clock_timestamp(),
          coalesce(nullif(trim(coalesce(d->>'tipoRegistro','')),''), v_tipo), v_ubic, p.codigo_afs, v_lote, v_venc, v_cantidad,
          upper(d->>'unidad'), v_unidades, d->>'usuario', d->>'referencia', d->>'observacion',
          coalesce((d->>'fueraRotacion')::boolean, false), nullif(trim(coalesce(d->>'motivo','')),''));
end $$;

alter function public.mov_(jsonb) security definer;
revoke all on function public.mov_(jsonb) from public, anon, authenticated;

select 'Listo: rotación activada' as resultado;
