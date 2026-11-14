-- =====================================================================
--  BODEGA ATLANTIC · Script 7: Calidad con fotos y link por producto
--  - Cada foto de evidencia puede ser de un producto de la factura (item_id)
--  - Cada producto recibido puede tener un link que agrega Calidad
--  Pégalo en Supabase → SQL Editor → Run. Se puede correr más de una vez.
-- =====================================================================
alter table public.evidencias add column if not exists item_id uuid references public.recepcion_items(id) on delete cascade;
create index if not exists evidencias_item on public.evidencias (item_id);
alter table public.recepcion_items add column if not exists link_calidad text;

select 'Listo: fotos y link por producto' as resultado;
