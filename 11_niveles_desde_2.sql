-- =====================================================================
--  BODEGA ATLANTIC · Script 11: los niveles empiezan en el 2
--  El nivel 1 de la bodega es el PICKING (código PK). Los niveles de
--  almacenamiento que ya estaban creados se corren uno hacia arriba:
--      1A → 2A,  2A → 3A,  3B → 4B …   (el picking PKA / PKB no cambia)
--  También se actualiza dónde está cada producto, los movimientos y los rótulos.
--  Pégalo en Supabase → SQL Editor → Run.
--  Es seguro correrlo otra vez: si ya se hizo, no vuelve a correr los niveles.
-- =====================================================================

create table if not exists public.migraciones (
  nombre text primary key,
  fecha  timestamptz not null default now()
);
alter table public.migraciones enable row level security;

do $$
declare
  fk record;
  fks text[] := '{}';
  defs text[] := '{}';
  i int;
begin
  if exists (select 1 from public.migraciones where nombre = 'niveles_desde_2') then
    raise notice 'Los niveles ya estaban corridos. No se cambió nada.';
    return;
  end if;

  -- Viejo → nuevo (solo niveles de almacenamiento, no el picking)
  create temp table mapa_niv on commit drop as
    select espacio_id as viejo,
           regexp_replace(espacio_id, '-' || codigo || '$', '-' || (nivel + 1)::text || lado) as nuevo,
           nivel + 1 as nivel_nuevo,
           (nivel + 1)::text || lado as codigo_nuevo
    from public.espacios
    where nivel >= 1;

  -- Quita por un momento las llaves que apuntan a espacios
  for fk in
    select c.conname, c.conrelid::regclass::text as tabla, pg_get_constraintdef(c.oid) as def
    from pg_constraint c
    where c.contype = 'f' and c.confrelid = 'public.espacios'::regclass
  loop
    fks := fks || (fk.tabla || '|' || fk.conname);
    defs := defs || fk.def;
    execute format('alter table %s drop constraint %I', fk.tabla, fk.conname);
  end loop;

  -- Primero con un nombre temporal (~) para que no choquen, luego el definitivo
  update public.espacios e set espacio_id = '~' || m.nuevo, nivel = m.nivel_nuevo, codigo = m.codigo_nuevo
    from mapa_niv m where e.espacio_id = m.viejo;
  update public.espacios set espacio_id = substr(espacio_id, 2) where espacio_id like '~%';

  update public.inventario x set ubicacion_id = '~' || m.nuevo from mapa_niv m where x.ubicacion_id = m.viejo;
  update public.inventario set ubicacion_id = substr(ubicacion_id, 2) where ubicacion_id like '~%';

  update public.movimientos x set ubicacion_id = m.nuevo from mapa_niv m where x.ubicacion_id = m.viejo;
  update public.etiquetas x set ubicacion_id = m.nuevo from mapa_niv m where x.ubicacion_id = m.viejo;

  -- Vuelve a poner las llaves
  for i in 1 .. coalesce(array_length(fks, 1), 0) loop
    execute format('alter table %s add constraint %I %s', split_part(fks[i], '|', 1), split_part(fks[i], '|', 2), defs[i]);
  end loop;

  insert into public.migraciones (nombre) values ('niveles_desde_2');
  raise notice 'Listo: % espacios pasaron al nivel siguiente.', (select count(*) from mapa_niv);
end $$;

select 'Listo: los niveles empiezan en el 2 (el 1 es el picking)' as resultado;
