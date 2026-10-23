begin;
alter table public.docks drop constraint docks_check;
alter table public.docks add constraint docks_check check(
 (building=100 and side='Parking Lot' and dock_number between 1 and 31)
 or (building=200 and side='Parking Lot' and dock_number between 32 and 58)
 or (building=200 and side='Opposite Side' and dock_number between 1 and 31));
-- Internal dock identifiers 56/57/58 are displayed as Wall 3/Wall 2/Wall 1.
insert into public.docks(building,side,dock_number,status)
values(200,'Parking Lot',56,'Open Dock'),(200,'Parking Lot',57,'Open Dock'),(200,'Parking Lot',58,'Open Dock')
on conflict(building,side,dock_number) do nothing;
commit;
