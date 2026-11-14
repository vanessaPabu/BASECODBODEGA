-- =====================================================================
--  BODEGA ATLANTIC · Script 10: lista de la factura (lo que debe llegar)
--  Se copian el código y la cantidad de la factura; quedan "por recibir"
--  hasta que el personal llene lo que de verdad llegó.
--  Pégalo en Supabase → SQL Editor → Run. Se puede correr más de una vez.
-- =====================================================================

alter table public.recepcion_items add column if not exists pendiente boolean not null default false;

select 'Listo: lista de la factura' as resultado;
