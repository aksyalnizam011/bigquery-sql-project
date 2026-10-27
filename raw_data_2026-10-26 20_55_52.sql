#1. Bagaimana tren pertumbuhan pendapatan (revenue) dari bulan ke bulan? Apakah ada lonjakan pada bulan-bulan tertentu (misalnya musim liburan)?

WITH monthly_sales AS (
    SELECT 
        FORMAT_DATE('%Y-%m', order_date) AS bulan,
        ROUND(SUM(revenue), 2) AS total_pendapatan,
        ROUND(AVG(revenue), 2) AS rata_rata_pendapatan
    FROM 
        `ecommerce_sales_analytics_2.raw_data`
    GROUP BY 
        bulan
)
SELECT 
    bulan,
    total_pendapatan,
    -- Mengambil pendapatan bulan sebelumnya
    LAG(total_pendapatan) OVER (ORDER BY bulan ASC) AS pendapatan_bulan_lalu,
    -- Menghitung persentase pertumbuhan MoM (%)
    ROUND(
        ((total_pendapatan - LAG(total_pendapatan) OVER (ORDER BY bulan ASC)) 
        / LAG(total_pendapatan) OVER (ORDER BY bulan ASC)) * 100, 
    2) AS mom_growth_percent
FROM 
    monthly_sales
ORDER BY 
    bulan ASC;

#Kategori produk apa yang memberikan total pendapatan (revenue) terbesar?

#Kategori apa yang paling banyak dibeli dalam hal kuantitas fisik (quantity)?

#Apakah kategori dengan pendapatan tertinggi juga memiliki tingkat kepuasan pelanggan (customer_rating) yang tinggi?
SELECT 
    product_category,
    COUNT(order_id) AS total_transaksi,
    SUM(quantity) AS total_unit_terjual,
    ROUND(SUM(revenue), 2) AS total_pendapatan,
    ROUND(AVG(revenue), 2) AS rata_rata_pendapatan_per_transaksi,
    ROUND(AVG(discount) * 100, 2) AS rata_rata_diskon_persen,
    ROUND(AVG(customer_rating), 2) AS rata_rata_rating_pelanggan
FROM 
    `ecommerce_sales_analytics_2.raw_data`
GROUP BY 
    product_category
ORDER BY 
    total_pendapatan DESC;

#Siapa saja pelanggan dengan kontribusi pendapatan terbesar (Top Customers)?

#Berapa persentase pelanggan yang melakukan pembelian berulang (repeat customers) dibandingkan yang hanya sekali belanja?

#Apakah ada hubungan antara jumlah transaksi yang dilakukan seorang pelanggan dengan rata-rata rating yang mereka berikan? 

SELECT 
    customer_id,
    COUNT(order_id) AS total_transaksi,
    SUM(quantity) AS total_unit_dibeli,
    ROUND(SUM(revenue), 2) AS total_belanja,
    ROUND(AVG(revenue), 2) AS rata_rata_belanja_per_transaksi,
    ROUND(AVG(customer_rating), 2) AS rata_rata_rating_diberikan
FROM 
    `ecommerce_sales_analytics_2.raw_data`
GROUP BY 
    customer_id
ORDER BY 
    total_belanja DESC;
#Wilayah mana yang memiliki rata-rata waktu pengiriman (delivery_days) paling lambat?

#Apakah lama hari pengiriman berpengaruh secara signifikan terhadap rating yang diberikan pelanggan? (Apakah pengiriman lambat membuat rating turun?)

#Metode pembayaran apa (payment_method) yang paling populer digunakan oleh pelanggan? Apakah metode tertentu mendominasi transaksi bernilai tinggi?

SELECT 
    region,
    payment_method,
    COUNT(order_id) AS total_transaksi,
    ROUND(AVG(delivery_days), 1) AS rata_rata_hari_pengiriman,
    MIN(delivery_days) AS pengiriman_tercepat,
    MAX(delivery_days) AS pengiriman_terlama,
    ROUND(AVG(customer_rating), 2) AS rata_rata_rating_pelanggan,
    ROUND(SUM(revenue), 2) AS total_pendapatan_metode
FROM 
    `ecommerce_sales_analytics_2.raw_data`
GROUP BY 
    region,
    payment_method
ORDER BY 
    region ASC, 
    total_transaksi DESC;

#Seberapa besar korelasi antara besaran diskon (discount) dengan jumlah kuantitas produk yang dibeli? Apakah diskon besar benar-benar mendongkrak volume penjualan secara signifikan?

#Apakah pemberian diskon yang terlalu besar justru menurunkan margin atau pendapatan bersih secara keseluruhan?

SELECT 
    CASE 
        WHEN discount = 0 THEN '1. No Discount (0%)'
        WHEN discount > 0 AND discount <= 0.10 THEN '2. Low Discount (1% - 10%)'
        WHEN discount > 0.10 AND discount <= 0.20 THEN '3. Medium Discount (11% - 20%)'
        ELSE '4. High Discount (>20%)'
    END AS discount_tier,
    COUNT(order_id) AS total_transaksi,
    SUM(quantity) AS total_unit_terjual,
    ROUND(AVG(quantity), 2) AS rata_rata_unit_per_transaksi,
    ROUND(SUM(revenue), 2) AS total_pendapatan,
    ROUND(AVG(revenue), 2) AS rata_rata_pendapatan_per_transaksi,
    ROUND(AVG(customer_rating), 2) AS rata_rata_rating_pelanggan
FROM 
    `ecommerce_sales_analytics_2.raw_data`
GROUP BY 
    discount_tier
ORDER BY 
    discount_tier ASC;