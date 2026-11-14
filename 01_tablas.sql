-- =====================================================================
--  BODEGA ATLANTIC · Script 1: tablas, seguridad, funciones y plano
--  Pégalo completo en Supabase → SQL Editor → New query → Run.
--  Se puede correr más de una vez: no borra datos que ya existan.
-- =====================================================================

-- ---------- Usuarios de la app (se crean solos al registrar un usuario) ----------
create table if not exists public.perfiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  nombre      text not null,
  rol         text not null default 'OPERARIO' check (rol in ('OPERARIO','JEFE')),
  activo      boolean not null default true,
  creado_en   timestamptz not null default now()
);

create or replace function public.crear_perfil() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.perfiles (id, nombre, rol)
  values (new.id,
          coalesce(nullif(new.raw_user_meta_data->>'nombre',''), split_part(new.email,'@',1)),
          case when upper(new.raw_user_meta_data->>'rol') = 'JEFE' then 'JEFE' else 'OPERARIO' end)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists al_crear_usuario on auth.users;
create trigger al_crear_usuario after insert on auth.users
  for each row execute function public.crear_perfil();

create or replace function public.es_jefe() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfiles where id = auth.uid() and rol = 'JEFE' and activo);
$$;

-- ---------- Estructura de la bodega ----------
create table if not exists public.sedes (
  id      text primary key,               -- S1, S2
  nombre  text not null,
  orden   int  not null default 0
);

create table if not exists public.zonas (
  id       text primary key,              -- SEC, CON… (Sede 2: B2-SEC, B2-REF…)
  sede_id  text not null references public.sedes(id),
  nombre   text not null,
  color    text not null default '#7A8794',
  x int, y int, ancho int, alto int,       -- posición en el dibujo del plano
  orden    int  not null default 0,
  activa   boolean not null default true
);

create table if not exists public.filas (
  id          text primary key,           -- SEC-F03, B2-SEC-F02
  zona_id     text not null references public.zonas(id),
  numero      int  not null,
  nombre      text not null,              -- "Fila 3"
  posiciones  int  not null check (posiciones > 0),
  fondo       text not null default 'D' check (fondo in ('D','S')),   -- D = A-B-C-D · S = A-B
  niveles     int  not null default 0,
  picking     boolean not null default false,                        -- tiene nivel 0
  pasillos    int[] not null default '{}',                           -- después de qué posición hay paso cruzado
  tramos      jsonb not null default '[]',                           -- dibujo: [{x,y,largo,pos,ancho}]
  orden       int  not null default 0,
  activa      boolean not null default true
);

create table if not exists public.espacios (
  id        text primary key,             -- código que se escanea: SEC-F03-P005-2A · SEC-F03-P005-PKA
  fila_id   text not null references public.filas(id),
  posicion  int  not null,
  nivel     int  not null,                -- 0 = picking
  lado      text not null check (lado in ('A','B','C','D')),
  activo    boolean not null default true,
  unique (fila_id, posicion, nivel, lado)
);

-- ---------- Productos ----------
create table if not exists public.productos (
  codigo_afs      text primary key,
  codigo_nutresa  text,
  nombre          text not null,
  unidad_medida   text not null default 'CJ',
  und_x_caja      int  not null default 1,
  codigo_barras   text,
  activo          boolean not null default true
);
create index if not exists productos_nutresa on public.productos (codigo_nutresa);
create index if not exists productos_barras  on public.productos (codigo_barras);

-- ---------- Rótulos (cada rótulo = un lote con su vencimiento) ----------
create sequence if not exists public.rotulo_seq start 1;

create table if not exists public.rotulos (
  id                 text primary key,     -- E000001
  codigo_afs         text not null references public.productos(codigo_afs),
  cajas              int  not null check (cajas > 0),
  embalaje           int  not null,
  total              int  not null,
  fecha_recibo       date not null default current_date,
  fecha_vencimiento  date not null,
  responsable        text not null,
  estado             text not null default 'PENDIENTE' check (estado in ('PENDIENTE','UBICADO','ANULADO')),
  espacio_id         text references public.espacios(id),
  creado_en          timestamptz not null default now(),
  creado_por         text,
  ubicado_en         timestamptz,
  ubicado_por        text
);

-- ---------- Inventario actual (qué hay en cada espacio) ----------
create table if not exists public.inventario (
  id                 uuid primary key default gen_random_uuid(),
  espacio_id         text not null references public.espacios(id),
  codigo_afs         text not null references public.productos(codigo_afs),
  lote               text not null default 'SIN-LOTE',   -- número de rótulo
  fecha_vencimiento  date,
  cajas              int  not null check (cajas >= 0),
  ingresado_en       timestamptz not null default now(),
  actualizado_en     timestamptz not null default now(),
  unique (espacio_id, codigo_afs, lote)
);
create index if not exists inventario_afs  on public.inventario (codigo_afs);
create index if not exists inventario_venc on public.inventario (fecha_vencimiento);

-- ---------- Historial de movimientos ----------
-- El id lo genera el celular: si el mismo movimiento se sube dos veces (sin internet → con internet) no se duplica.
create table if not exists public.movimientos (
  id                 uuid primary key,
  fecha              timestamptz not null default now(),   -- cuándo lo hizo el operario
  subido_en          timestamptz not null default now(),   -- cuándo llegó al servidor
  tipo               text not null check (tipo in ('ENTRADA','SALIDA','TRASLADO','AJUSTE')),
  espacio_id         text not null references public.espacios(id),
  destino_id         text references public.espacios(id),
  codigo_afs         text not null references public.productos(codigo_afs),
  lote               text not null,
  fecha_vencimiento  date,
  cajas              int  not null,
  usuario_id         uuid references public.perfiles(id),
  usuario_nombre     text,
  referencia         text,
  observacion        text,
  estado             text not null default 'APLICADO' check (estado in ('APLICADO','POR_REVISAR')),
  nota               text
);
create index if not exists movimientos_fecha on public.movimientos (fecha desc);

-- =====================================================================
--  Funciones que usa la app
-- =====================================================================

-- Registra una entrada, salida o traslado. Si no alcanza el producto, queda POR_REVISAR (no daña el inventario).
create or replace function public.registrar_movimiento(m jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id     uuid := (m->>'id')::uuid;
  v_tipo   text := upper(m->>'tipo');
  v_cajas  int  := (m->>'cajas')::int;
  v_esp    text := m->>'espacio_id';
  v_dest   text := nullif(m->>'destino_id','');
  v_afs    text := m->>'codigo_afs';
  v_lote   text := coalesce(nullif(m->>'lote',''), 'SIN-LOTE');
  v_venc   date := nullif(m->>'fecha_vencimiento','')::date;
  v_fecha  timestamptz := coalesce(nullif(m->>'fecha','')::timestamptz, now());
  v_user   uuid := auth.uid();
  v_nombre text;
  v_hay    int;
  v_venc2  date;
  v_estado text := 'APLICADO';
  v_nota   text;
begin
  if v_user is null then raise exception 'Inicia sesión para registrar movimientos'; end if;
  if exists (select 1 from movimientos where id = v_id) then
    return jsonb_build_object('id', v_id, 'estado', (select estado from movimientos where id = v_id), 'repetido', true);
  end if;
  if v_cajas is null or v_cajas <= 0 then raise exception 'La cantidad de cajas debe ser mayor que 0'; end if;
  select nombre into v_nombre from perfiles where id = v_user;

  if v_tipo = 'ENTRADA' then
    insert into inventario (espacio_id, codigo_afs, lote, fecha_vencimiento, cajas)
    values (v_esp, v_afs, v_lote, v_venc, v_cajas)
    on conflict (espacio_id, codigo_afs, lote)
      do update set cajas = inventario.cajas + excluded.cajas, actualizado_en = now();

  elsif v_tipo in ('SALIDA','TRASLADO') then
    select cajas, fecha_vencimiento into v_hay, v_venc2
      from inventario where espacio_id = v_esp and codigo_afs = v_afs and lote = v_lote for update;
    v_venc := coalesce(v_venc2, v_venc);
    if v_tipo = 'TRASLADO' and (v_dest is null or v_dest = v_esp) then
      raise exception 'Elige un espacio destino diferente al de origen';
    end if;
    if coalesce(v_hay, 0) < v_cajas then
      v_estado := 'POR_REVISAR';
      v_nota := format('Se pidieron %s cj pero en %s había %s', v_cajas, v_esp, coalesce(v_hay, 0));
    else
      update inventario set cajas = cajas - v_cajas, actualizado_en = now()
        where espacio_id = v_esp and codigo_afs = v_afs and lote = v_lote;
      delete from inventario where espacio_id = v_esp and codigo_afs = v_afs and lote = v_lote and cajas = 0;
      if v_tipo = 'TRASLADO' then
        insert into inventario (espacio_id, codigo_afs, lote, fecha_vencimiento, cajas)
        values (v_dest, v_afs, v_lote, v_venc, v_cajas)
        on conflict (espacio_id, codigo_afs, lote)
          do update set cajas = inventario.cajas + excluded.cajas, actualizado_en = now();
        -- si el lote completo cambió de lugar, el rótulo apunta al nuevo espacio
        update rotulos set espacio_id = v_dest
          where id = v_lote and not exists (select 1 from inventario where espacio_id = v_esp and lote = v_lote);
      end if;
    end if;
  else
    raise exception 'Tipo de movimiento desconocido: %', v_tipo;
  end if;

  insert into movimientos (id, fecha, tipo, espacio_id, destino_id, codigo_afs, lote, fecha_vencimiento, cajas,
                           usuario_id, usuario_nombre, referencia, observacion, estado, nota)
  values (v_id, v_fecha, v_tipo, v_esp, v_dest, v_afs, v_lote, v_venc, v_cajas,
          v_user, v_nombre, m->>'referencia', m->>'observacion', v_estado, v_nota);

  -- al ubicar un rótulo nuevo, queda marcado como UBICADO
  if v_tipo = 'ENTRADA' and v_estado = 'APLICADO' then
    update rotulos set estado = 'UBICADO', espacio_id = v_esp, ubicado_en = v_fecha, ubicado_por = v_nombre
      where id = v_lote and estado = 'PENDIENTE';
  end if;

  return jsonb_build_object('id', v_id, 'estado', v_estado, 'nota', v_nota);
end $$;

-- Crea los espacios de una fila completa (o de una sola posición). No borra los que ya existen.
create or replace function public.crear_niveles(p_fila text, p_niveles int, p_picking boolean, p_posicion int default null)
returns int
language plpgsql security definer set search_path = public as $$
declare
  f public.filas;
  v_creados int;
begin
  if not es_jefe() then raise exception 'Solo el jefe puede crear niveles'; end if;
  select * into f from filas where id = p_fila;
  if f.id is null then raise exception 'No existe la fila %', p_fila; end if;
  if p_niveles < 1 or p_niveles > 12 then raise exception 'Los niveles deben estar entre 1 y 12'; end if;

  insert into espacios (id, fila_id, posicion, nivel, lado)
  select f.id || '-P' || lpad(pos::text, 3, '0') || '-' || case when niv = 0 then 'PK' else niv::text end || lado,
         f.id, pos, niv, lado
  from generate_series(coalesce(p_posicion, 1), coalesce(p_posicion, f.posiciones)) pos,
       generate_series(case when p_picking then 0 else 1 end, p_niveles) niv,
       unnest(case when f.fondo = 'D' then array['A','B','C','D'] else array['A','B'] end) lado
  on conflict do nothing;
  get diagnostics v_creados = row_count;

  if p_posicion is null then
    update filas set niveles = p_niveles, picking = p_picking where id = f.id;
  end if;
  return v_creados;
end $$;

-- Crea un rótulo con el siguiente número (E000001, E000002…)
create or replace function public.crear_rotulo(r jsonb) returns public.rotulos
language plpgsql security definer set search_path = public as $$
declare
  p public.productos;
  v public.rotulos;
begin
  if auth.uid() is null then raise exception 'Inicia sesión para crear rótulos'; end if;
  select * into p from productos where codigo_afs = r->>'codigo_afs';
  if p.codigo_afs is null then raise exception 'No existe el código AFS %', r->>'codigo_afs'; end if;
  insert into rotulos (id, codigo_afs, cajas, embalaje, total, fecha_recibo, fecha_vencimiento, responsable, creado_por)
  values ('E' || lpad(nextval('rotulo_seq')::text, 6, '0'), p.codigo_afs, (r->>'cajas')::int, p.und_x_caja,
          (r->>'cajas')::int * p.und_x_caja, coalesce(nullif(r->>'fecha_recibo','')::date, current_date),
          (r->>'fecha_vencimiento')::date, r->>'responsable',
          (select nombre from perfiles where id = auth.uid()))
  returning * into v;
  return v;
end $$;

-- ---------- Vista para reportes: inventario con todos sus datos ----------
create or replace view public.v_inventario with (security_invoker = true) as
select i.id, z.sede_id, s.nombre as sede, z.id as zona_id, z.nombre as zona, f.id as fila_id, f.nombre as fila,
       e.id as espacio_id, e.posicion, e.nivel, e.lado,
       i.codigo_afs, p.codigo_nutresa, p.nombre as producto, p.unidad_medida, p.und_x_caja,
       i.lote, i.fecha_vencimiento, i.cajas, i.cajas * p.und_x_caja as unidades,
       (i.fecha_vencimiento - current_date) as dias_para_vencer,
       case when i.fecha_vencimiento is null then 'SIN FECHA'
            when i.fecha_vencimiento < current_date then 'VENCIDO'
            when i.fecha_vencimiento <= current_date + 7 then 'VENCE PRONTO'
            else 'BIEN' end as estado,
       i.ingresado_en, i.actualizado_en
from inventario i
join espacios e on e.id = i.espacio_id
join filas f    on f.id = e.fila_id
join zonas z    on z.id = f.zona_id
join sedes s    on s.id = z.sede_id
join productos p on p.codigo_afs = i.codigo_afs;

-- =====================================================================
--  Seguridad (RLS): todos los usuarios con sesión pueden ver;
--  solo el jefe cambia la estructura y los productos;
--  inventario y movimientos solo se cambian por las funciones de arriba.
-- =====================================================================
alter table public.perfiles    enable row level security;
alter table public.sedes       enable row level security;
alter table public.zonas       enable row level security;
alter table public.filas       enable row level security;
alter table public.espacios    enable row level security;
alter table public.productos   enable row level security;
alter table public.rotulos     enable row level security;
alter table public.inventario  enable row level security;
alter table public.movimientos enable row level security;

do $$
declare t text;
begin
  foreach t in array array['perfiles','sedes','zonas','filas','espacios','productos','rotulos','inventario','movimientos'] loop
    execute format('drop policy if exists ver on public.%I', t);
    execute format('create policy ver on public.%I for select to authenticated using (true)', t);
  end loop;
  foreach t in array array['sedes','zonas','filas','espacios','productos','perfiles'] loop
    execute format('drop policy if exists jefe_edita on public.%I', t);
    execute format('create policy jefe_edita on public.%I for all to authenticated using (public.es_jefe()) with check (public.es_jefe())', t);
  end loop;
end $$;

revoke all on function public.registrar_movimiento(jsonb) from public, anon;
revoke all on function public.crear_niveles(text, int, boolean, int) from public, anon;
revoke all on function public.crear_rotulo(jsonb) from public, anon;
grant execute on function public.registrar_movimiento(jsonb) to authenticated;
grant execute on function public.crear_niveles(text, int, boolean, int) to authenticated;
grant execute on function public.crear_rotulo(jsonb) to authenticated;

-- =====================================================================
--  Datos del plano: Sede 1 (Bodega 12C) y Sede 2 (Bodega 2)
-- =====================================================================
insert into public.sedes (id, nombre, orden) values
  ('S1','Bodega 12C',1), ('S2','Bodega 2',2)
on conflict (id) do nothing;

insert into public.zonas (id, sede_id, nombre, color, x, y, ancho, alto, orden) values
  ('CON','S1','Congelados','#D9534F',14,8,296,424,1),
  ('CGL','S1','Congelación','#E57373',14,432,296,262,2),
  ('PIC','S1','Zona de picking','#8E44AD',14,694,106,198,3),
  ('RFG','S1','Refrigeración','#9B59B6',205,694,105,102,4),
  ('PRO','S1','Cuarto de proceso','#9B59B6',205,796,105,96,5),
  ('REF','S1','Refrigerado','#1F9BA6',322,614,182,278,6),
  ('SEC','S1','Seco','#7A8794',322,8,598,604,7),
  ('ATE','S1','Atemperado','#C2185B',625,614,295,278,8),
  ('B2-REF','S2','Refri','#1F9BA6',30,50,690,800,9),
  ('B2-CAV','S2','Cava','#4A90D9',42,62,300,380,10),
  ('B2-SEC','S2','Seco','#C2185B',730,50,880,800,11)
on conflict (id) do nothing;

insert into public.filas (id, zona_id, numero, nombre, posiciones, fondo, picking, pasillos, tramos, orden)
select id, zona_id, numero, 'Fila ' || numero, posiciones, fondo, fondo = 'D', pasillos::int[], tramos::jsonb, orden
from (values
  ('CON-F01','CON',1,16,'D','{}','[{"x":32,"y":18,"largo":408,"pos":16,"ancho":34}]',1),
  ('CON-F02','CON',2,14,'D','{}','[{"x":143,"y":18,"largo":357,"pos":14,"ancho":34}]',2),
  ('CON-F03','CON',3,16,'D','{}','[{"x":254,"y":18,"largo":408,"pos":16,"ancho":34}]',3),
  ('CGL-F01','CGL',1,16,'D','{}','[{"x":32,"y":442,"largo":246,"pos":16,"ancho":34}]',4),
  ('CGL-F02','CGL',2,13,'D','{}','[{"x":143,"y":442,"largo":200,"pos":13,"ancho":34}]',5),
  ('CGL-F03','CGL',3,16,'D','{}','[{"x":254,"y":442,"largo":246,"pos":16,"ancho":34}]',6),
  ('PIC-F01','PIC',1,8,'D','{}','[{"x":28,"y":708,"largo":176,"pos":8,"ancho":34}]',7),
  ('REF-F01','REF',1,10,'D','{}','[{"x":334,"y":626,"largo":260,"pos":10,"ancho":34}]',8),
  ('REF-F02','REF',2,10,'D','{}','[{"x":446,"y":626,"largo":260,"pos":10,"ancho":34}]',9),
  ('SEC-F01','SEC',1,10,'D','{}','[{"x":334,"y":16,"largo":462,"pos":10,"ancho":34}]',10),
  ('SEC-F02','SEC',2,31,'D','{10}','[{"x":446,"y":16,"largo":590,"pos":31,"ancho":34}]',11),
  ('SEC-F03','SEC',3,16,'S','{8}','[{"x":512,"y":16,"largo":872,"pos":16,"ancho":20}]',12),
  ('SEC-F04','SEC',4,16,'S','{8}','[{"x":594,"y":16,"largo":872,"pos":16,"ancho":20}]',13),
  ('SEC-F05','SEC',5,31,'D','{19}','[{"x":634,"y":40,"largo":560,"pos":31,"ancho":34}]',14),
  ('SEC-F06','SEC',6,31,'D','{19}','[{"x":744,"y":40,"largo":560,"pos":31,"ancho":34}]',15),
  ('SEC-F07','SEC',7,31,'D','{}','[{"x":872,"y":40,"largo":560,"pos":31,"ancho":34}]',16),
  ('ATE-F01','ATE',1,10,'D','{}','[{"x":634,"y":626,"largo":260,"pos":10,"ancho":34}]',17),
  ('ATE-F02','ATE',2,10,'D','{}','[{"x":748,"y":626,"largo":260,"pos":10,"ancho":34}]',18),
  ('ATE-F03','ATE',3,10,'D','{}','[{"x":868,"y":626,"largo":260,"pos":10,"ancho":34}]',19),
  ('B2-CAV-F01','B2-CAV',1,3,'S','{}','[{"x":60,"y":85,"largo":330,"pos":3,"ancho":40}]',20),
  ('B2-CAV-F02','B2-CAV',2,3,'S','{}','[{"x":270,"y":105,"largo":300,"pos":3,"ancho":40}]',21),
  ('B2-REF-F01','B2-REF',1,3,'S','{}','[{"x":70,"y":540,"largo":290,"pos":3,"ancho":32}]',22),
  ('B2-REF-F02','B2-REF',2,1,'S','{}','[{"x":225,"y":535,"largo":120,"pos":1,"ancho":26}]',23),
  ('B2-REF-F03','B2-REF',3,5,'S','{}','[{"x":390,"y":115,"largo":460,"pos":5,"ancho":40}]',24),
  ('B2-REF-F04','B2-REF',4,5,'S','{}','[{"x":540,"y":115,"largo":460,"pos":5,"ancho":40}]',25),
  ('B2-REF-F05','B2-REF',5,6,'S','{}','[{"x":667,"y":95,"largo":560,"pos":6,"ancho":32}]',26),
  ('B2-SEC-F01','B2-SEC',1,7,'S','{}','[{"x":965,"y":90,"largo":740,"pos":7,"ancho":26}]',27),
  ('B2-SEC-F02','B2-SEC',2,14,'S','{}','[{"x":991,"y":90,"largo":740,"pos":7,"ancho":26},{"x":1095,"y":90,"largo":740,"pos":7,"ancho":26}]',28),
  ('B2-SEC-F03','B2-SEC',3,14,'S','{}','[{"x":1121,"y":90,"largo":740,"pos":7,"ancho":26},{"x":1215,"y":110,"largo":640,"pos":7,"ancho":26}]',29),
  ('B2-SEC-F04','B2-SEC',4,14,'S','{}','[{"x":1295,"y":110,"largo":640,"pos":7,"ancho":26},{"x":1395,"y":130,"largo":600,"pos":7,"ancho":26}]',30),
  ('B2-SEC-F05','B2-SEC',5,14,'S','{}','[{"x":1423,"y":130,"largo":600,"pos":7,"ancho":26},{"x":1520,"y":90,"largo":700,"pos":7,"ancho":26}]',31),
  ('B2-SEC-F06','B2-SEC',6,7,'S','{}','[{"x":1546,"y":90,"largo":700,"pos":7,"ancho":26}]',32),
  ('B2-SEC-F07','B2-SEC',7,6,'S','{}','[{"x":780,"y":110,"largo":620,"pos":6,"ancho":40}]',33)
) as t(id, zona_id, numero, posiciones, fondo, pasillos, tramos, orden)
on conflict (id) do nothing;

-- Producto de ejemplo para probar (los 3.000 se cargan después desde Excel/CSV)
insert into public.productos (codigo_afs, codigo_nutresa, nombre, unidad_medida, und_x_caja)
values ('2680','1049449','GALLETA FESTIVAL MINICHIPS BOLSA X12UND','CJ',12)
on conflict (codigo_afs) do nothing;

select 'Listo: ' || (select count(*) from public.sedes) || ' sedes, '
       || (select count(*) from public.zonas) || ' zonas, '
       || (select count(*) from public.filas) || ' filas' as resultado;
