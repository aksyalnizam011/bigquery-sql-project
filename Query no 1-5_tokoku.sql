-- ---------------------------------------------------------------------
-- QUERY 1: TREN PENJUALAN BULANAN
-- Menjawab: (pendapatan per bulan), (naik/turun vs tahun lalu),
--           (jumlah pesanan dan rata-rata nilai pesanan),
--           (persentase pembatalan dan tren)
-- ---------------------------------------------------------------------
WITH nilai AS (
    SELECT id_pesanan, SUM(total_bayar) AS nilai
    FROM dataset_tokoku.detail_bersih
    GROUP BY id_pesanan
),
pesanan AS (
    SELECT
        DATE_TRUNC(p.tanggal_pesanan, MONTH) AS bulan,
        p.status,
        COALESCE(n.nilai, 0) AS nilai
    FROM dataset_tokoku.pesanan_bersih p
    LEFT JOIN nilai n ON n.id_pesanan = p.id_pesanan
),
bulanan AS (
    SELECT
        bulan,
        COUNT(*)                                            AS jumlah_pesanan,
        COUNTIF(status = 'Dibatalkan')                      AS pesanan_dibatalkan,
        ROUND(100 * COUNTIF(status = 'Dibatalkan') / COUNT(*), 1) AS persen_dibatalkan,
        SUM(IF(status = 'Selesai', nilai, 0))               AS pendapatan,
        ROUND(SUM(IF(status = 'Selesai', nilai, 0))
              / NULLIF(COUNTIF(status = 'Selesai'), 0))     AS rata_rata_nilai_pesanan
    FROM pesanan
    WHERE bulan IS NOT NULL
    GROUP BY bulan
)
SELECT
    bulan,
    jumlah_pesanan,
    pesanan_dibatalkan,
    persen_dibatalkan,
    CAST(ROUND(pendapatan) AS INT64)                        AS pendapatan_rp,
    ROUND(pendapatan / 1000000, 1)                          AS pendapatan_juta_rp,
    CAST(rata_rata_nilai_pesanan AS INT64)                  AS rata_rata_nilai_pesanan_rp,
    ROUND(100 * (pendapatan - LAG(pendapatan, 12) OVER (ORDER BY bulan))
          / NULLIF(LAG(pendapatan, 12) OVER (ORDER BY bulan), 0), 1) AS pertumbuhan_yoy_persen
FROM bulanan
ORDER BY bulan;

-- ---------------------------------------------------------------------
-- QUERY 2: PELANGGAN PER KOTA
-- Menjawab: (jumlah pelanggan aktif), (kota dengan pelanggan dan
--           pendapatan terbesar), (one-time vs repeat buyer)
-- Baris SEMUA KOTA berisi total keseluruhan (dari ROLLUP).
-- ---------------------------------------------------------------------
WITH nilai AS (
    SELECT id_pesanan, SUM(total_bayar) AS nilai
    FROM dataset_tokoku.detail_bersih
    GROUP BY id_pesanan
),
pesanan_semua AS (
    SELECT
        p.id_pelanggan,
        p.status,
        p.tanggal_pesanan,
        p.pelanggan_valid,
        COALESCE(n.nilai, 0) AS nilai
    FROM dataset_tokoku.pesanan_bersih p
    LEFT JOIN nilai n ON n.id_pesanan = p.id_pesanan
),
acuan AS (
    SELECT MAX(tanggal_pesanan) AS tgl_terakhir
    FROM dataset_tokoku.pesanan_bersih
),
per_pelanggan AS (
    SELECT
        pl.id_pelanggan,
        pl.kota,
        1 AS is_pelanggan,
        COUNTIF(pv.status = 'Selesai')                   AS jumlah_pesanan_selesai,
        COUNTIF(pv.status = 'Selesai'
                AND pv.tanggal_pesanan >= DATE_SUB(a.tgl_terakhir, INTERVAL 3 MONTH)) AS pesanan_selesai_3_bulan,
        SUM(IF(pv.status = 'Selesai', pv.nilai, 0))      AS total_belanja
    FROM dataset_tokoku.pelanggan_bersih pl
    LEFT JOIN pesanan_semua pv ON pv.id_pelanggan = pl.id_pelanggan
    CROSS JOIN acuan a
    GROUP BY pl.id_pelanggan, pl.kota
 
    UNION ALL
 
    SELECT
        CAST(NULL AS STRING)                             AS id_pelanggan,
        'Tidak terhubung pelanggan'                      AS kota,
        0                                                AS is_pelanggan,
        COUNTIF(pv.status = 'Selesai')                   AS jumlah_pesanan_selesai,
        0                                                AS pesanan_selesai_3_bulan,
        SUM(IF(pv.status = 'Selesai', pv.nilai, 0))      AS total_belanja
    FROM pesanan_semua pv
    WHERE pv.pelanggan_valid = 0
)
SELECT
    CASE WHEN GROUPING(kota) = 1 THEN 'SEMUA KOTA' ELSE kota END AS kota_tampil,
    SUM(is_pelanggan)                                    AS jumlah_pelanggan,
    COUNTIF(is_pelanggan = 1 AND jumlah_pesanan_selesai > 0)  AS pelanggan_aktif_sepanjang_waktu,
    COUNTIF(is_pelanggan = 1 AND pesanan_selesai_3_bulan > 0) AS pelanggan_aktif_3_bulan_terakhir,
    COUNTIF(is_pelanggan = 1 AND jumlah_pesanan_selesai >= 2) AS repeat_buyer,
    ROUND(100 * COUNTIF(is_pelanggan = 1 AND jumlah_pesanan_selesai >= 2)
          / NULLIF(COUNTIF(is_pelanggan = 1 AND jumlah_pesanan_selesai > 0), 0), 1) AS persen_repeat_buyer,
    CAST(ROUND(SUM(total_belanja)) AS INT64)             AS pendapatan_rp,
    ROUND(SUM(total_belanja) / 1000000, 1)               AS pendapatan_juta_rp,
    CAST(ROUND(SUM(total_belanja) / NULLIF(SUM(jumlah_pesanan_selesai), 0)) AS INT64) AS rata_rata_nilai_pesanan_rp
FROM per_pelanggan
GROUP BY ROLLUP(kota)
ORDER BY pendapatan_rp DESC;

-- ---------------------------------------------------------------------
-- QUERY 3: PELANGGAN PALING BERNILAI
-- Menjawab: (top customer), (waktu dari daftar ke pesanan pertama),
--           (pesanan dari pelanggan valid saja)
-- Menampilkan 10 pelanggan dengan total belanja tertinggi.
-- ---------------------------------------------------------------------
WITH nilai AS (
    SELECT id_pesanan, SUM(total_bayar) AS nilai
    FROM dataset_tokoku.detail_bersih
    GROUP BY id_pesanan
),
pesanan_valid AS (
    SELECT p.id_pelanggan, p.status, p.tanggal_pesanan, COALESCE(n.nilai, 0) AS nilai
    FROM dataset_tokoku.pesanan_bersih p
    LEFT JOIN nilai n ON n.id_pesanan = p.id_pesanan
    WHERE p.pelanggan_valid = 1
)
SELECT
    pl.id_pelanggan,
    pl.nama,
    pl.kota,
    COUNTIF(pv.status = 'Selesai')                        AS jumlah_pesanan_selesai,
    CAST(ROUND(SUM(IF(pv.status = 'Selesai', pv.nilai, 0))) AS INT64) AS total_belanja_rp,
    MIN(pv.tanggal_pesanan)                               AS pesanan_pertama,
    -- hari dikosongkan (NULL) bila pesanan pertama tercatat sebelum tanggal daftar,
    -- agar nilai negatif tidak ikut dihitung dalam rata-rata
    IF(MIN(pv.tanggal_pesanan) < pl.tanggal_daftar, NULL,
       DATE_DIFF(MIN(pv.tanggal_pesanan), pl.tanggal_daftar, DAY)) AS hari_daftar_ke_pesanan_pertama,
    -- 1 = pesanan pertama tercatat SEBELUM tanggal daftar (data perlu diperiksa)
    IF(MIN(pv.tanggal_pesanan) < pl.tanggal_daftar, 1, 0) AS pesanan_sebelum_daftar
FROM dataset_tokoku.pelanggan_bersih pl
JOIN pesanan_valid pv ON pv.id_pelanggan = pl.id_pelanggan
GROUP BY pl.id_pelanggan, pl.nama, pl.kota, pl.tanggal_daftar
ORDER BY total_belanja_rp DESC
LIMIT 10;

-- ---------------------------------------------------------------------
-- QUERY 4: PRODUK DAN KATEGORI
-- Menjawab: (produk terlaris unit dan pendapatan), (kontribusi
--           kategori), (produk tidak pernah terjual), (dampak
--           diskon), (harga transaksi sesuai harga resmi)
-- ---------------------------------------------------------------------
WITH detail_selesai AS (
    SELECT d.id_produk, d.jumlah, d.harga_satuan, d.total_bayar, d.produk_valid
    FROM dataset_tokoku.detail_bersih d
    JOIN dataset_tokoku.pesanan_bersih p ON p.id_pesanan = d.id_pesanan
    WHERE p.status = 'Selesai' AND d.jumlah IS NOT NULL
),
per_produk AS (
    SELECT
        id_produk,
        SUM(jumlah)                       AS unit_terjual,
        SUM(total_bayar)                  AS pendapatan,
        SUM(jumlah * harga_satuan)        AS pendapatan_kotor,
        MIN(harga_satuan)                 AS harga_terendah_transaksi,
        MAX(harga_satuan)                 AS harga_tertinggi_transaksi
    FROM detail_selesai
    WHERE produk_valid = 1
    GROUP BY id_produk
),
hasil AS (
    SELECT
        pr.id_produk,
        pr.nama_produk,
        pr.kategori,
        pr.harga_satuan                                   AS harga_resmi,
        pr.stok,
        COALESCE(pp.unit_terjual, 0)                      AS unit_terjual,
        COALESCE(pp.pendapatan, 0)                        AS pendapatan,
        COALESCE(pp.pendapatan_kotor, 0)                  AS pendapatan_kotor,
        pp.harga_terendah_transaksi,
        pp.harga_tertinggi_transaksi,
        IF(pp.id_produk IS NULL, 'Tidak pernah terjual', 'Terjual') AS status_penjualan
    FROM dataset_tokoku.produk_bersih pr
    LEFT JOIN per_produk pp ON pp.id_produk = pr.id_produk
 
    UNION ALL
 
    SELECT
        'PRODUK TIDAK DIKENAL',
        'Produk tidak ada di tabel master',
        'Tidak diketahui',
        CAST(NULL AS INT64),
        CAST(NULL AS INT64),
        COALESCE(SUM(jumlah), 0),
        COALESCE(SUM(total_bayar), 0),
        COALESCE(SUM(jumlah * harga_satuan), 0),
        CAST(NULL AS INT64),
        CAST(NULL AS INT64),
        'Terjual'
    FROM detail_selesai
    WHERE produk_valid = 0
)
SELECT
    id_produk,
    nama_produk,
    kategori,
    harga_resmi,
    stok,
    unit_terjual,
    CAST(ROUND(pendapatan) AS INT64)                      AS pendapatan_rp,
    ROUND(pendapatan / 1000000, 1)                        AS pendapatan_juta_rp,
    CAST(ROUND(pendapatan_kotor - pendapatan) AS INT64)   AS potongan_diskon_rp,
    ROUND(100 * pendapatan / NULLIF(SUM(pendapatan) OVER (), 0), 2) AS persen_dari_total,
    ROUND(100 * SUM(pendapatan) OVER (PARTITION BY kategori)
          / NULLIF(SUM(pendapatan) OVER (), 0), 2)        AS kontribusi_kategori_persen,
    RANK() OVER (ORDER BY unit_terjual DESC)              AS rank_unit,
    RANK() OVER (ORDER BY pendapatan DESC)                AS rank_pendapatan,
    harga_terendah_transaksi,
    harga_tertinggi_transaksi,
    status_penjualan
FROM hasil
ORDER BY pendapatan_rp DESC;

-- ---------------------------------------------------------------------
-- QUERY 5: PEMBAYARAN DAN OPERASIONAL
-- Menjawab: (metode pembayaran terpopuler), (metode vs pembatalan),
--           (pesanan yang menggantung)
-- Baris TOTAL berisi angka keseluruhan (dari ROLLUP).
-- ---------------------------------------------------------------------
WITH data_pesanan AS (
    SELECT
        COALESCE(metode_bayar, 'Tidak diketahui') AS metode,
        status,
        tanggal_pesanan
    FROM dataset_tokoku.pesanan_bersih
),
acuan AS (
    SELECT MAX(tanggal_pesanan) AS tgl_terakhir
    FROM dataset_tokoku.pesanan_bersih
)
SELECT
    COALESCE(d.metode, 'TOTAL')                           AS metode_bayar,
    COUNT(*)                                              AS jumlah_pesanan,
    ROUND(100 * COUNT(*)
          / (SELECT COUNT(*) FROM dataset_tokoku.pesanan_bersih), 1) AS persen_pesanan,
    COUNTIF(d.status = 'Dibatalkan')                      AS dibatalkan,
    ROUND(100 * COUNTIF(d.status = 'Dibatalkan')
          / NULLIF(COUNTIF(d.status IS NOT NULL), 0), 1)  AS persen_dibatalkan,
    COUNTIF(d.status IN ('Diproses', 'Dikirim')
            AND d.tanggal_pesanan < DATE_SUB(a.tgl_terakhir, INTERVAL 30 DAY)) AS menggantung_lebih_30_hari
FROM data_pesanan d
CROSS JOIN acuan a
GROUP BY ROLLUP(d.metode)
ORDER BY jumlah_pesanan DESC;