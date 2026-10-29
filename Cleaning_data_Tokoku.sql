-- ---------------------------------------------------------------------
-- 1. PRODUK
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE dataset_tokoku.produk_bersih AS
SELECT
    TRIM(id_produk)                                 AS id_produk,
    TRIM(nama_produk)                               AS nama_produk,
    CASE UPPER(TRIM(kategori))
        WHEN 'ELEKTRONIK'   THEN 'Elektronik'
        WHEN 'FASHION'      THEN 'Fashion'
        WHEN 'RUMAH TANGGA' THEN 'Rumah Tangga'
        WHEN 'OLAHRAGA'     THEN 'Olahraga'
        WHEN 'BUKU'         THEN 'Buku'
        ELSE TRIM(kategori)
    END                                             AS kategori,
    SAFE_CAST(TRIM(harga_satuan) AS INT64)          AS harga_satuan,
    SAFE_CAST(NULLIF(TRIM(stok), '') AS INT64)      AS stok
FROM dataset_tokoku.produk;

SELECT table_name, table_type
FROM dataset_tokoku.INFORMATION_SCHEMA.TABLES;

-- ---------------------------------------------------------------------
-- 2. PELANGGAN
--    2a. normalisasi email, no_hp, kota, tanggal_daftar
--    2b. deteksi duplikat (sama email ATAU sama no_hp)
--        pelanggan dengan id lebih kecil dianggap data asli
--    2c. buang duplikat dari tabel utama
-- ---------------------------------------------------------------------
 
-- 2a. normalisasi
CREATE OR REPLACE TABLE dataset_tokoku.pelanggan_norm AS
SELECT
    TRIM(id_pelanggan)                              AS id_pelanggan,
    TRIM(nama)                                      AS nama,
    NULLIF(LOWER(TRIM(email)), '')                  AS email,
    -- no_hp: +62 8xx -> 08xx, hapus tanda hubung dan spasi
    CASE
        WHEN TRIM(no_hp) = ''                       THEN NULL
        WHEN TRIM(no_hp) LIKE '+62%'
            THEN CONCAT('0', REPLACE(REPLACE(SUBSTR(TRIM(no_hp), 4), '-', ''), ' ', ''))
        ELSE REPLACE(REPLACE(TRIM(no_hp), '-', ''), ' ', '')
    END                                             AS no_hp,
    -- kota: satukan variasi penulisan
    CASE UPPER(TRIM(kota))
        WHEN 'JAKARTA'    THEN 'Jakarta'
        WHEN 'JKT'        THEN 'Jakarta'
        WHEN 'BANDUNG'    THEN 'Bandung'
        WHEN 'BDG'        THEN 'Bandung'
        WHEN 'SURABAYA'   THEN 'Surabaya'
        WHEN 'SBY'        THEN 'Surabaya'
        WHEN 'YOGYAKARTA' THEN 'Yogyakarta'
        WHEN 'YOGYA'      THEN 'Yogyakarta'
        ELSE TRIM(kota)
    END                                             AS kota,
    -- tanggal_daftar: ubah dua format (yyyy-mm-dd dan dd/mm/yyyy) menjadi DATE
    COALESCE(
        SAFE.PARSE_DATE('%Y-%m-%d', TRIM(tanggal_daftar)),
        SAFE.PARSE_DATE('%d/%m/%Y', TRIM(tanggal_daftar))
    )                                               AS tanggal_daftar
FROM dataset_tokoku.pelanggan;
 
-- 2b. cari pasangan duplikat
CREATE OR REPLACE TABLE dataset_tokoku.map_pelanggan AS
SELECT
    d.id_pelanggan          AS id_duplikat,
    MIN(u.id_pelanggan)     AS id_utama
FROM dataset_tokoku.pelanggan_norm d
JOIN dataset_tokoku.pelanggan_norm u
  ON (d.email = u.email OR d.no_hp = u.no_hp)
 AND u.id_pelanggan < d.id_pelanggan
GROUP BY d.id_pelanggan;
 
-- 2c. tabel pelanggan final (tanpa duplikat)
CREATE OR REPLACE TABLE dataset_tokoku.pelanggan_bersih AS
SELECT *
FROM dataset_tokoku.pelanggan_norm
WHERE id_pelanggan NOT IN (SELECT id_duplikat FROM dataset_tokoku.map_pelanggan);

-- ---------------------------------------------------------------------
-- 3. PESANAN
--    - buang baris duplikat (id_pesanan sama)
--    - id_pelanggan duplikat diarahkan ke id utama
--    - id_pelanggan kosong -> NULL, id tidak dikenal ditandai pelanggan_valid = 0
--    - tanggal -> DATE
--    - status distandarisasi, status kosong -> NULL
--    - metode_bayar: 'qris' -> 'QRIS', kosong -> NULL
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE dataset_tokoku.pesanan_bersih AS
WITH unik AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY id_pesanan) AS rn
    FROM dataset_tokoku.pesanan
),
dasar AS (
    SELECT
        TRIM(u.id_pesanan)                          AS id_pesanan,
        CASE
            WHEN m.id_utama IS NOT NULL THEN m.id_utama
            ELSE NULLIF(TRIM(u.id_pelanggan), '')
        END                                         AS id_pelanggan,
        COALESCE(
            SAFE.PARSE_DATE('%Y-%m-%d', TRIM(u.tanggal_pesanan)),
            SAFE.PARSE_DATE('%d/%m/%Y', TRIM(u.tanggal_pesanan))
        )                                           AS tanggal_pesanan,
        CASE UPPER(TRIM(u.status))
            WHEN 'SELESAI'    THEN 'Selesai'
            WHEN 'DIBATALKAN' THEN 'Dibatalkan'
            WHEN 'DIKIRIM'    THEN 'Dikirim'
            WHEN 'DIPROSES'   THEN 'Diproses'
            ELSE NULL
        END                                         AS status,
        CASE
            WHEN TRIM(u.metode_bayar) = ''                THEN NULL
            WHEN UPPER(TRIM(u.metode_bayar)) = 'QRIS'     THEN 'QRIS'
            ELSE TRIM(u.metode_bayar)
        END                                         AS metode_bayar
    FROM unik u
    LEFT JOIN dataset_tokoku.map_pelanggan m ON m.id_duplikat = TRIM(u.id_pelanggan)
    WHERE u.rn = 1
)
SELECT
    b.*,
    CASE WHEN b.id_pelanggan IN (SELECT id_pelanggan FROM dataset_tokoku.pelanggan_bersih)
         THEN 1 ELSE 0 END                          AS pelanggan_valid
FROM dasar b;

-- ---------------------------------------------------------------------
-- 4. DETAIL PESANAN
--    - buang baris duplikat (id_detail sama)
--    - jumlah 0 -> NULL (dikecualikan dari analisis)
--    - jumlah negatif -> diubah jadi positif (asumsi salah tanda)
--    - harga kosong diisi dari tabel produk
--    - diskon kosong -> 0
--    - produk_valid = 0 jika id_produk tidak ada di tabel produk
--    - total_bayar = jumlah x harga x (1 - diskon)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE dataset_tokoku.detail_bersih AS
WITH unik AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY id_detail) AS rn
    FROM dataset_tokoku.detail_pesanan
),
dasar AS (
    SELECT
        TRIM(u.id_detail)                           AS id_detail,
        TRIM(u.id_pesanan)                          AS id_pesanan,
        TRIM(u.id_produk)                           AS id_produk,
        CASE
            WHEN SAFE_CAST(TRIM(u.jumlah) AS INT64) = 0 THEN NULL
            ELSE ABS(SAFE_CAST(TRIM(u.jumlah) AS INT64))
        END                                         AS jumlah,
        SAFE_CAST(NULLIF(TRIM(u.harga_satuan), '') AS INT64) AS harga_asal,
        COALESCE(SAFE_CAST(NULLIF(TRIM(u.diskon_persen), '') AS INT64), 0) AS diskon_persen
    FROM unik u
    WHERE u.rn = 1
)
SELECT
    d.id_detail,
    d.id_pesanan,
    d.id_produk,
    d.jumlah,
    COALESCE(d.harga_asal, p.harga_satuan)          AS harga_satuan,
    d.diskon_persen,
    CASE WHEN p.id_produk IS NULL THEN 0 ELSE 1 END AS produk_valid,
    ROUND(d.jumlah
          * COALESCE(d.harga_asal, p.harga_satuan)
          * (100 - d.diskon_persen) / 100.0)         AS total_bayar
FROM dasar d
LEFT JOIN dataset_tokoku.produk_bersih p ON p.id_produk = d.id_produk;

-- =====================================================================
-- 5. VALIDASI
-- =====================================================================
 
-- 5a. jumlah baris sebelum dan sesudah
SELECT 'pelanggan' AS tabel,
       (SELECT COUNT(*) FROM dataset_tokoku.pelanggan)         AS sebelum,
       (SELECT COUNT(*) FROM dataset_tokoku.pelanggan_bersih)  AS sesudah
UNION ALL
SELECT 'produk',
       (SELECT COUNT(*) FROM dataset_tokoku.produk),
       (SELECT COUNT(*) FROM dataset_tokoku.produk_bersih)
UNION ALL
SELECT 'pesanan',
       (SELECT COUNT(*) FROM dataset_tokoku.pesanan),
       (SELECT COUNT(*) FROM dataset_tokoku.pesanan_bersih)
UNION ALL
SELECT 'detail_pesanan',
       (SELECT COUNT(*) FROM dataset_tokoku.detail_pesanan),
       (SELECT COUNT(*) FROM dataset_tokoku.detail_bersih);
 
-- 5b. duplikat yang tersisa (harus kosong)
SELECT 'pesanan' AS tabel, id_pesanan AS kunci, COUNT(*) AS jumlah
FROM dataset_tokoku.pesanan_bersih GROUP BY id_pesanan HAVING COUNT(*) > 1
UNION ALL
SELECT 'detail', id_detail, COUNT(*)
FROM dataset_tokoku.detail_bersih GROUP BY id_detail HAVING COUNT(*) > 1;
 
-- 5c. nilai hasil standarisasi
SELECT 'status' AS kolom, status AS nilai, COUNT(*) AS jumlah
FROM dataset_tokoku.pesanan_bersih GROUP BY status
UNION ALL
SELECT 'kota', kota, COUNT(*) FROM dataset_tokoku.pelanggan_bersih GROUP BY kota
UNION ALL
SELECT 'kategori', kategori, COUNT(*) FROM dataset_tokoku.produk_bersih GROUP BY kategori
UNION ALL
SELECT 'metode_bayar', metode_bayar, COUNT(*) FROM dataset_tokoku.pesanan_bersih GROUP BY metode_bayar;
 
-- 5d. sisa masalah yang belum diperbaiki otomatis
SELECT 'pesanan tanpa dataset_tokoku.pelanggan valid' AS cek, COUNT(*) AS jumlah
FROM dataset_tokoku.pesanan_bersih WHERE pelanggan_valid = 0
UNION ALL
SELECT 'detail tanpa dataset_tokoku.produk valid', COUNT(*)
FROM dataset_tokoku.detail_bersih WHERE produk_valid = 0
UNION ALL
SELECT 'detail dengan jumlah NULL', COUNT(*)
FROM dataset_tokoku.detail_bersih WHERE jumlah IS NULL
UNION ALL
SELECT 'tanggal dataset_tokoku.pesanan gagal diparse', COUNT(*)
FROM dataset_tokoku.pesanan_bersih WHERE tanggal_pesanan IS NULL
UNION ALL
SELECT 'tanggal daftar dataset_tokoku.pelanggan gagal diparse', COUNT(*)
FROM dataset_tokoku.pelanggan_bersih WHERE tanggal_daftar IS NULL
UNION ALL
SELECT 'pelanggan tanpa email', COUNT(*)
FROM dataset_tokoku.pelanggan_bersih WHERE email IS NULL;
 
-- 5e. daftar duplikat pelanggan yang digabung
SELECT m.id_duplikat, m.id_utama, n.nama, n.email, n.no_hp
FROM dataset_tokoku.map_pelanggan m
JOIN dataset_tokoku.pelanggan_norm n ON n.id_pelanggan = m.id_duplikat
ORDER BY m.id_duplikat;