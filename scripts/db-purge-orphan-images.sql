-- Hapus gambar wajah (tabel img) yang tidak lagi dirujuk embedding mana pun.
--
-- Latar belakang: pada CompreFace 1.2.0, DELETE /api/v1/recognition/subjects/{subject} dan
-- DELETE /api/v1/recognition/faces?subject=... menghapus subject/embedding tetapi MENINGGALKAN
-- baris img (data biometrik) — terverifikasi 2026-09-29 (docs/test-evidence/2026-09-29/
-- tc-subject-deletion.txt). Jalankan skrip ini setelah penghapusan subject / secara terjadwal
-- untuk memenuhi hak penghapusan data (lihat docs/SECURITY.md §6.3).
--
--   psql -U <user> -d frs -v ON_ERROR_STOP=1 -f scripts/db-purge-orphan-images.sql
begin;
select count(*) as orphan_img_sebelum from img i
 where not exists (select 1 from embedding e where e.img_id = i.id);
delete from img i
 where not exists (select 1 from embedding e where e.img_id = i.id);
select count(*) as orphan_img_sesudah from img i
 where not exists (select 1 from embedding e where e.img_id = i.id);
commit;
-- Ruang disk dikembalikan ke OS setelah VACUUM (autovacuum) — untuk penghapusan besar:
--   VACUUM (VERBOSE) img;
