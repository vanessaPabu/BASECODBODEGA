-- =====================================================================
--  BODEGA ATLANTIC · Script 4: espacios llenos y rótulos de peso variable
--  1. Un espacio que ya tiene producto no recibe otro producto.
--  2. Rótulo normal: si cambian las unidades por caja, quedan guardadas en el producto.
--  3. Rótulo de peso variable: peso neto = báscula − estiba − (peso cava × cavas).
--  Pégalo en Supabase → SQL Editor → Run. Se puede correr más de una vez.
-- =====================================================================
alter table public.etiquetas alter column embalaje type numeric using embalaje::numeric;
alter table public.etiquetas alter column total type numeric using total::numeric;
alter table public.etiquetas add column if not exists tipo text not null default 'NORMAL';
alter table public.etiquetas add column if not exists peso_cava numeric;
alter table public.etiquetas add column if not exists num_cavas int;
alter table public.etiquetas add column if not exists peso_estiba numeric;
alter table public.etiquetas add column if not exists peso_bascula numeric;

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

  -- Un espacio lleno no recibe otro producto (sí se puede sumar al mismo producto y lote que ya está ahí)
  if v_tipo = 'ENTRADA' and exists (select 1 from inventario where ubicacion_id = v_ubic and cantidad_unidades > 0
      and not (producto_id = p.codigo_afs and lote = v_lote)) then
    raise exception 'El espacio % ya está ocupado con otro producto. Elige un espacio vacío.', v_ubic;
  end if;

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

-- Crear rótulo: NORMAL (cajas × unidades por caja) o PESO (peso variable)
create or replace function public.bd_crear_etiqueta(d jsonb) returns public.etiquetas
language plpgsql security definer set search_path = public as $$
declare
  p        public.productos;
  e        public.etiquetas;
  v_tipo   text := upper(coalesce(nullif(d->>'tipo',''), 'NORMAL'));
  v_cajas  int;
  v_und    int;
  v_pc     numeric; v_pe numeric; v_pb numeric; v_neto numeric;
begin
  select * into p from productos where codigo_afs = trim(coalesce(d->>'codigo',''));
  if p.codigo_afs is null then raise exception 'Producto no encontrado'; end if;
  if coalesce(d->>'vencimiento','') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Escribe la fecha de vencimiento'; end if;
  if trim(coalesce(d->>'responsable','')) = '' then raise exception 'Elige el responsable'; end if;

  if v_tipo = 'PESO' then
    v_cajas := floor(nullif(d->>'numCavas','')::numeric);
    v_pc := coalesce(nullif(d->>'pesoCava','')::numeric, 0);
    v_pe := coalesce(nullif(d->>'pesoEstiba','')::numeric, 0);
    v_pb := nullif(d->>'pesoBascula','')::numeric;
    if v_cajas is null or v_cajas <= 0 then raise exception 'Escribe cuántas cavas o cajas llegaron'; end if;
    if v_pb is null or v_pb <= 0 then raise exception 'Escribe el peso de la báscula'; end if;
    v_neto := round(v_pb - v_pe - v_pc * v_cajas, 2);
    if v_neto <= 0 then raise exception 'El peso neto da % kg. Revisa los pesos.', v_neto; end if;
    insert into etiquetas (etiqueta_id, codigo, producto, codigo_nutresa, cajas, embalaje, total, fecha_recibo, fecha_vencimiento,
                           responsable, estado, tipo, peso_cava, num_cavas, peso_estiba, peso_bascula)
    values ('E' || lpad(nextval('etiqueta_seq')::text, 6, '0'), p.codigo_afs, p.nombre, p.codigo_nutresa, v_cajas,
            round(v_neto / v_cajas, 2), v_neto, coalesce(nullif(d->>'recibo','')::date, current_date), (d->>'vencimiento')::date,
            trim(d->>'responsable'), 'PENDIENTE', 'PESO', v_pc, v_cajas, v_pe, v_pb)
    returning * into e;
  else
    v_cajas := floor(nullif(d->>'cajas','')::numeric);
    v_und := coalesce(floor(nullif(d->>'undXCaja','')::numeric)::int, p.und_x_caja);
    if v_cajas is null or v_cajas <= 0 then raise exception 'Escribe el número de cajas'; end if;
    if v_und is null or v_und <= 0 then raise exception 'Escribe las unidades por caja'; end if;
    -- Las unidades por caja quedan guardadas en el producto para la próxima vez
    if v_und <> p.und_x_caja then update productos set und_x_caja = v_und where codigo_afs = p.codigo_afs; end if;
    insert into etiquetas (etiqueta_id, codigo, producto, codigo_nutresa, cajas, embalaje, total, fecha_recibo, fecha_vencimiento,
                           responsable, estado, tipo)
    values ('E' || lpad(nextval('etiqueta_seq')::text, 6, '0'), p.codigo_afs, p.nombre, p.codigo_nutresa, v_cajas, v_und,
            v_cajas * v_und, coalesce(nullif(d->>'recibo','')::date, current_date), (d->>'vencimiento')::date,
            trim(d->>'responsable'), 'PENDIENTE', 'NORMAL')
    returning * into e;
  end if;
  return e;
end $$;

-- Ubicar rótulo: el normal entra en cajas; el de peso variable entra en kilos
create or replace function public.bd_ubicar_etiqueta(d jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare e public.etiquetas;
begin
  select * into e from etiquetas where upper(etiqueta_id) = upper(trim(coalesce(d->>'etiquetaId',''))) for update;
  if e.etiqueta_id is null then raise exception 'Identificador no encontrado'; end if;
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

revoke all on function public.bd_crear_etiqueta(jsonb) from public, anon;
revoke all on function public.bd_ubicar_etiqueta(jsonb) from public, anon;
grant execute on function public.bd_crear_etiqueta(jsonb), public.bd_ubicar_etiqueta(jsonb) to authenticated;

select 'Listo: espacios llenos y peso variable' as resultado;
