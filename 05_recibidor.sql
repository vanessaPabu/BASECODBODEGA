-- =====================================================================
--  BODEGA ATLANTIC · Script 5: Recibidor (recibo por factura) y Calidad
--  - recepciones: una por factura (factura, proveedor, fecha de ingreso)
--  - recepcion_items: lo que dice la factura y lo que llegó, con lote y vencimiento
--  - evidencias: fotos de cómo llegó la mercancía (se guardan en Storage, carpeta "evidencias")
--  Pégalo en Supabase → SQL Editor → Run. Se puede correr más de una vez.
-- =====================================================================

create table if not exists public.recepciones (
  id             uuid primary key default gen_random_uuid(),
  factura        text not null,
  proveedor      text not null,
  fecha_ingreso  date not null default current_date,
  sede_id        text references public.sedes(id),
  recibido_por   text,
  estado         text not null default 'ABIERTA' check (estado in ('ABIERTA','CERRADA')),
  observacion    text,
  creado_en      timestamptz not null default now()
);
create index if not exists recepciones_fecha on public.recepciones (fecha_ingreso desc);
create unique index if not exists recepciones_factura on public.recepciones (upper(proveedor), upper(factura));

create table if not exists public.recepcion_items (
  id                 uuid primary key default gen_random_uuid(),
  recepcion_id       uuid not null references public.recepciones(id) on delete cascade,
  codigo_afs         text not null,
  producto           text not null,
  unidad_medida      text,
  cantidad_factura   numeric,            -- lo que dice la factura
  cantidad_recibida  numeric not null,   -- lo que llegó
  lote               text,
  fecha_vencimiento  date,
  novedad            text,               -- nota: caja rota, faltante, etc.
  etiquetas          text[] not null default '{}',   -- rótulos que se imprimieron para este ítem
  creado_por         text,
  creado_en          timestamptz not null default now()
);
create index if not exists recepcion_items_rec on public.recepcion_items (recepcion_id);

create table if not exists public.evidencias (
  id            uuid primary key default gen_random_uuid(),
  recepcion_id  uuid not null references public.recepciones(id) on delete cascade,
  ruta          text not null,           -- ruta del archivo en Storage (carpeta evidencias)
  nombre        text,
  nota          text,
  subido_por    text,
  creado_en     timestamptz not null default now()
);
create index if not exists evidencias_rec on public.evidencias (recepcion_id);

-- Seguridad: igual que el resto de la app (solo equipos activados)
do $$
declare t text;
begin
  foreach t in array array['recepciones','recepcion_items','evidencias'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists app on public.%I', t);
    execute format('create policy app on public.%I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

-- Carpeta privada para las fotos de evidencia
insert into storage.buckets (id, name, public) values ('evidencias', 'evidencias', false)
on conflict (id) do nothing;

drop policy if exists "evidencias_ver" on storage.objects;
drop policy if exists "evidencias_subir" on storage.objects;
drop policy if exists "evidencias_borrar" on storage.objects;
create policy "evidencias_ver" on storage.objects for select to authenticated using (bucket_id = 'evidencias');
create policy "evidencias_subir" on storage.objects for insert to authenticated with check (bucket_id = 'evidencias');
create policy "evidencias_borrar" on storage.objects for delete to authenticated using (bucket_id = 'evidencias');

select 'Listo: recibidor y calidad' as resultado;
