-- =====================================================================
--  BODEGA ATLANTIC · Script 2: base de datos igual a la app original (Apps Script)
--  Reemplaza lo que creó el Script 1 (todavía no tenía datos reales).
--  Pégalo completo en Supabase → SQL Editor → New query → Run.
--
--  Cada pestaña de la hoja de cálculo original es ahora una tabla:
--    Sedes, Operarios, Espacios, Productos, Inventario, Movimientos, Etiquetas
--  y lo que antes se guardaba en "propiedades del proyecto" (cambios de zonas
--  y racks) queda en la tabla sede_config.
--  El plano de cada sede sigue en el código de la app, como en la original.
-- =====================================================================

-- ---------- Borrar lo del Script 1 ----------
drop view if exists public.v_inventario;
drop function if exists public.registrar_movimiento(jsonb);
drop function if exists public.crear_niveles(text, int, boolean, int);
drop function if exists public.crear_rotulo(jsonb);
drop table if exists public.movimientos cascade;
drop table if exists public.inventario cascade;
drop table if exists public.rotulos cascade;
drop table if exists public.espacios cascade;
drop table if exists public.filas cascade;
drop table if exists public.zonas cascade;
drop table if exists public.productos cascade;
drop sequence if exists public.rotulo_seq;
drop trigger if exists al_crear_usuario on auth.users;
drop function if exists public.crear_perfil();
drop policy if exists jefe_edita on public.sedes;
drop policy if exists ver on public.sedes;
drop function if exists public.es_jefe() cascade;
drop table if exists public.perfiles cascade;

-- ---------- Tablas (mismas columnas que las pestañas originales) ----------
create table if not exists public.sedes (
  id      text primary key,          -- SedeID
  nombre  text not null,
  orden   int  not null default 0    -- la 1.ª sede usa el plano de la Bodega 12C, la 2.ª el de la Bodega 2
);

create table public.operarios (
  operario_id  text primary key,
  nombre       text not null unique,
  rol          text not null default 'OPERARIO' check (rol in ('OPERARIO','JEFE')),
  activo       boolean not null default true
);

-- Cambios de nombres de zonas, zonas nuevas y ajustes de racks (antes: propiedades CFG_<sede>)
create table public.sede_config (
  sede_id  text primary key references public.sedes(id),
  cfg      jsonb not null default '{}'
);

create table public.espacios (
  espacio_id  text primary key,       -- SEC-F03-P005-2A · SEC-F03-P005-PKA · B2-SEC-F02-P003-1B
  rack_id     text not null,
  posicion    int  not null,
  nivel       int  not null,          -- 0 = Picking
  lado        text not null,
  codigo      text not null,          -- 2A, PKA…
  activo      boolean not null default true
);
create index espacios_rack on public.espacios (rack_id);

create table public.productos (
  codigo_afs        text primary key,
  codigo_nutresa    text,
  nombre            text not null,
  unidad_medida     text,
  und_x_caja        int  not null default 1,
  cajas_por_estiba  int  not null default 1,
  codigo_barras     text,
  activo            boolean not null default true
);

create table public.inventario (
  inventario_id        text primary key default ('INV-' || gen_random_uuid()),
  ubicacion_id         text not null references public.espacios(espacio_id),
  producto_id          text not null references public.productos(codigo_afs),
  lote                 text not null default '',
  fecha_vencimiento    date,
  cantidad_unidades    numeric not null check (cantidad_unidades >= 0),
  fecha_actualizacion  timestamptz not null default now(),
  fecha_ingreso        timestamptz not null default now(),
  unique (ubicacion_id, producto_id, lote)
);

create table public.movimientos (
  movimiento_id      text primary key,
  fecha              timestamptz not null default now(),
  tipo               text not null,     -- ENTRADA, SALIDA, TRASLADO-SALIDA, TRASLADO-ENTRADA
  ubicacion_id       text not null,
  producto_id        text not null,
  lote               text,
  fecha_vencimiento  date,
  cantidad           numeric not null,
  unidad_medida      text,              -- UND, CAJA, ESTIBA
  cantidad_unidades  numeric not null,
  usuario            text,
  referencia_id      text,
  observacion        text
);
create index movimientos_fecha on public.movimientos (fecha desc);

create sequence public.etiqueta_seq start 1;
create table public.etiquetas (
  etiqueta_id        text primary key,  -- E000001
  fecha_creacion     timestamptz not null default now(),
  codigo             text not null,     -- código AFS
  producto           text not null,
  codigo_nutresa     text,
  cajas              int  not null,
  embalaje           int  not null,
  total              int  not null,
  fecha_recibo       date not null,
  fecha_vencimiento  date not null,
  responsable        text not null,
  estado             text not null default 'PENDIENTE',   -- PENDIENTE / UBICADA
  ubicacion_id       text,
  fecha_ubicacion    timestamptz,
  ubicado_por        text
);

-- =====================================================================
--  Entradas y salidas (igual que movimiento_ de la app original)
--  Se hacen dentro de la base de datos para que dos personas al tiempo no choquen.
-- =====================================================================
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

  insert into movimientos (movimiento_id, tipo, ubicacion_id, producto_id, lote, fecha_vencimiento, cantidad,
                           unidad_medida, cantidad_unidades, usuario, referencia_id, observacion)
  values (coalesce(nullif(d->>'movimientoId',''), 'MOV-' || gen_random_uuid()),
          coalesce(nullif(trim(coalesce(d->>'tipoRegistro','')),''), v_tipo), v_ubic, p.codigo_afs, v_lote, v_venc, v_cantidad,
          upper(d->>'unidad'), v_unidades, d->>'usuario', d->>'referencia', d->>'observacion');
end $$;

-- bdMovimiento: entrada o salida
create or replace function public.bd_movimiento(d jsonb) returns void
language plpgsql set search_path = public as $$
begin
  -- Si el mismo movimiento llega dos veces (por ejemplo al recuperar internet), no se repite
  if nullif(d->>'movimientoId','') is not null and exists (select 1 from movimientos where movimiento_id = d->>'movimientoId') then
    return;
  end if;
  perform mov_(d);
end $$;

-- bdMover: pasa producto de un espacio a otro (también entre sedes). Conserva lote y vencimiento.
create or replace function public.bd_mover(d jsonb) returns void
language plpgsql set search_path = public as $$
declare
  v_origen  text := trim(coalesce(d->>'origenId',''));
  v_destino text := trim(coalesce(d->>'destinoId',''));
  v_lote    text := trim(coalesce(d->>'lote',''));
  l         public.inventario;
  v_ref     text := 'TRA-' || to_char(now(), 'YYMMDDHH24MISS') || '-' || floor(random() * 1000);
  comun     jsonb;
begin
  if v_destino = '' then raise exception 'Elige el espacio de destino'; end if;
  if v_origen = v_destino then raise exception 'El destino es el mismo espacio de origen'; end if;
  select * into l from inventario where ubicacion_id = v_origen and producto_id = trim(coalesce(d->>'productoId','')) and lote = v_lote;
  if l.inventario_id is null then raise exception 'Ese producto ya no está en el espacio de origen'; end if;

  comun := jsonb_build_object('productoId', d->>'productoId', 'cantidad', d->>'cantidad', 'unidad', d->>'unidad',
             'lote', v_lote, 'vencimiento', l.fecha_vencimiento, 'usuario', d->>'usuario', 'referencia', v_ref);
  perform mov_(comun || jsonb_build_object('tipo','SALIDA','ubicacionId',v_origen,'tipoRegistro','TRASLADO-SALIDA','observacion','Movido a ' || v_destino));
  perform mov_(comun || jsonb_build_object('tipo','ENTRADA','ubicacionId',v_destino,'tipoRegistro','TRASLADO-ENTRADA','observacion','Movido desde ' || v_origen));

  -- Si el lote es un rótulo y ya no queda nada en el origen, el rótulo pasa a la nueva ubicación
  if not exists (select 1 from inventario where ubicacion_id = v_origen and lote = v_lote and cantidad_unidades > 0) then
    update etiquetas set ubicacion_id = v_destino where upper(etiqueta_id) = upper(v_lote);
  end if;
end $$;

-- bdCrearEtiqueta: crea el identificador (rótulo) con el siguiente número
create or replace function public.bd_crear_etiqueta(d jsonb) returns public.etiquetas
language plpgsql set search_path = public as $$
declare
  p public.productos;
  v_cajas int := floor(nullif(d->>'cajas','')::numeric);
  e public.etiquetas;
begin
  select * into p from productos where codigo_afs = trim(coalesce(d->>'codigo',''));
  if p.codigo_afs is null then raise exception 'Producto no encontrado'; end if;
  if v_cajas is null or v_cajas <= 0 then raise exception 'Escribe el número de cajas'; end if;
  if coalesce(d->>'vencimiento','') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'Escribe la fecha de vencimiento'; end if;
  if trim(coalesce(d->>'responsable','')) = '' then raise exception 'Elige el responsable'; end if;
  insert into etiquetas (etiqueta_id, codigo, producto, codigo_nutresa, cajas, embalaje, total, fecha_recibo,
                         fecha_vencimiento, responsable, estado)
  values ('E' || lpad(nextval('etiqueta_seq')::text, 6, '0'), p.codigo_afs, p.nombre, p.codigo_nutresa, v_cajas,
          p.und_x_caja, v_cajas * p.und_x_caja, coalesce(nullif(d->>'recibo','')::date, current_date),
          (d->>'vencimiento')::date, trim(d->>'responsable'), 'PENDIENTE')
  returning * into e;
  return e;
end $$;

-- bdUbicarEtiqueta: pone en un espacio lo que dice el rótulo (entrada en cajas con su vencimiento)
create or replace function public.bd_ubicar_etiqueta(d jsonb) returns void
language plpgsql set search_path = public as $$
declare e public.etiquetas;
begin
  select * into e from etiquetas where upper(etiqueta_id) = upper(trim(coalesce(d->>'etiquetaId',''))) for update;
  if e.etiqueta_id is null then raise exception 'Identificador no encontrado'; end if;
  if e.estado = 'UBICADA' then raise exception 'Este identificador ya se ubicó en %', e.ubicacion_id; end if;
  perform mov_(jsonb_build_object('tipo','ENTRADA','ubicacionId',d->>'ubicacionId','productoId',e.codigo,'cantidad',e.cajas,
     'unidad','CAJA','lote',e.etiqueta_id,'vencimiento',e.fecha_vencimiento,'usuario',d->>'usuario','referencia',e.etiqueta_id,
     'observacion','Recibido ' || e.fecha_recibo || ' · Responsable ' || e.responsable));
  update etiquetas set estado = 'UBICADA', ubicacion_id = trim(d->>'ubicacionId'), fecha_ubicacion = now(), ubicado_por = d->>'usuario'
    where etiqueta_id = e.etiqueta_id;
end $$;

-- =====================================================================
--  Seguridad: la app entra con una cuenta de la bodega (se activa una vez por equipo).
--  Sin esa sesión no se puede leer ni escribir nada.
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['sedes','operarios','sede_config','espacios','productos','inventario','movimientos','etiquetas'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists app on public.%I', t);
    execute format('create policy app on public.%I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

revoke all on function public.mov_(jsonb) from public, anon, authenticated;
revoke all on function public.bd_movimiento(jsonb) from public, anon;
revoke all on function public.bd_mover(jsonb) from public, anon;
revoke all on function public.bd_crear_etiqueta(jsonb) from public, anon;
revoke all on function public.bd_ubicar_etiqueta(jsonb) from public, anon;
grant execute on function public.bd_movimiento(jsonb), public.bd_mover(jsonb),
                          public.bd_crear_etiqueta(jsonb), public.bd_ubicar_etiqueta(jsonb) to authenticated;
-- mov_ solo se usa desde las otras funciones
alter function public.mov_(jsonb) security definer;
alter function public.bd_movimiento(jsonb) security definer;
alter function public.bd_mover(jsonb) security definer;
alter function public.bd_crear_etiqueta(jsonb) security definer;
alter function public.bd_ubicar_etiqueta(jsonb) security definer;
grant usage on sequence public.etiqueta_seq to authenticated;

-- =====================================================================
--  Datos iniciales (igual que la original)
-- =====================================================================
insert into public.sedes (id, nombre, orden) values ('S1','Bodega 12C',1), ('S2','Bodega 2',2)
on conflict (id) do nothing;
insert into public.operarios (operario_id, nombre, rol) values ('OP1','Operario 1','OPERARIO'), ('J1','Jefe 1','JEFE')
on conflict do nothing;
insert into public.productos (codigo_afs, codigo_nutresa, nombre, unidad_medida, und_x_caja)
values ('2680','1049449','GALLETA FESTIVAL MINICHIPS BOLSA X12UND','CJ',12)
on conflict do nothing;

select 'Listo: ' || (select count(*) from public.sedes) || ' sedes, ' || (select count(*) from public.operarios) || ' operarios' as resultado;
