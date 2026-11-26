DELIMITER //

DROP FUNCTION IF EXISTS fn_total_peminjaman_user//

CREATE FUNCTION fn_total_peminjaman_user(
    p_id_pengguna INT
)
RETURNS INT
READS SQL DATA
BEGIN
    DECLARE v_total INT DEFAULT 0;

    SELECT COUNT(*)
    INTO v_total
    FROM peminjaman
    WHERE id_pengguna = p_id_pengguna
      AND status <> 'ditolak';

    RETURN v_total;
END//


DROP FUNCTION IF EXISTS fn_status_ketersediaan_aset//

CREATE FUNCTION fn_status_ketersediaan_aset(
    p_id_aset INT
)
RETURNS VARCHAR(100)
READS SQL DATA
BEGIN
    DECLARE v_tersedia INT DEFAULT NULL;
    DECLARE v_total INT DEFAULT NULL;
    DECLARE CONTINUE HANDLER FOR NOT FOUND
        SET v_tersedia = NULL;

    SELECT jumlah_tersedia, jumlah_total
    INTO v_tersedia, v_total
    FROM aset
    WHERE id_aset = p_id_aset;

    IF v_tersedia IS NULL THEN
        RETURN 'Aset tidak ditemukan';
    ELSEIF v_tersedia > 0 THEN
        RETURN CONCAT('Tersedia (', v_tersedia, '/', v_total, ' unit)');
    ELSE
        RETURN 'Stok Habis';
    END IF;
END//


DROP FUNCTION IF EXISTS fn_hitung_denda//

CREATE FUNCTION fn_hitung_denda(
    p_id_peminjaman INT,
    p_tanggal_kembali DATETIME
)
RETURNS DECIMAL(10,2)
READS SQL DATA
BEGIN
    DECLARE v_denda DECIMAL(10,2) DEFAULT 0;

    SELECT COALESCE(
        SUM(
            GREATEST(
                DATEDIFF(
                    DATE(p_tanggal_kembali),
                    DATE(p.tanggal_selesai)
                ),
                0
            ) * k.denda_terlambat * dp.jumlah
        ),
        0
    )
    INTO v_denda
    FROM peminjaman p
    JOIN detail_peminjaman dp
        ON p.id_peminjaman = dp.id_peminjaman
    JOIN aset a
        ON dp.id_aset = a.id_aset
    JOIN kategori_aset k
        ON a.id_kategori = k.id_kategori
    WHERE p.id_peminjaman = p_id_peminjaman;

    RETURN v_denda;
END//


DROP PROCEDURE IF EXISTS sp_setujui_peminjaman//

CREATE PROCEDURE sp_setujui_peminjaman(
    IN p_id_peminjaman INT,
    IN p_id_petugas INT
)
BEGIN
    DECLARE v_status VARCHAR(20);
    DECLARE v_ada INT DEFAULT 0;
    DECLARE v_stok_kurang INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT COUNT(*)
    INTO v_ada
    FROM peminjaman
    WHERE id_peminjaman = p_id_peminjaman;

    IF v_ada = 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Peminjaman tidak ditemukan';
    END IF;

    SELECT status
    INTO v_status
    FROM peminjaman
    WHERE id_peminjaman = p_id_peminjaman
    FOR UPDATE;

    IF v_status <> 'diajukan' THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Peminjaman tidak dapat disetujui';
    END IF;

    SELECT COUNT(*)
    INTO v_ada
    FROM detail_peminjaman
    WHERE id_peminjaman = p_id_peminjaman;

    IF v_ada = 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Detail peminjaman belum tersedia';
    END IF;

    SELECT COUNT(*)
    INTO v_stok_kurang
    FROM (
        SELECT id_aset, SUM(jumlah) AS total_pinjam
        FROM detail_peminjaman
        WHERE id_peminjaman = p_id_peminjaman
        GROUP BY id_aset
    ) AS d
    JOIN aset a ON a.id_aset = d.id_aset
    WHERE a.jumlah_tersedia < d.total_pinjam;

    IF v_stok_kurang > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Stok aset tidak mencukupi';
    END IF;

    UPDATE aset a
    JOIN (
        SELECT id_aset, SUM(jumlah) AS total_pinjam
        FROM detail_peminjaman
        WHERE id_peminjaman = p_id_peminjaman
        GROUP BY id_aset
    ) AS d ON a.id_aset = d.id_aset
    SET a.jumlah_tersedia = a.jumlah_tersedia - d.total_pinjam;

    UPDATE peminjaman
    SET status = 'disetujui',
        id_petugas = p_id_petugas
    WHERE id_peminjaman = p_id_peminjaman;

    COMMIT;

    SELECT id_peminjaman, status, id_petugas
    FROM peminjaman
    WHERE id_peminjaman = p_id_peminjaman;
END//


DROP PROCEDURE IF EXISTS sp_proses_pengembalian//

CREATE PROCEDURE sp_proses_pengembalian(
    IN p_id_peminjaman INT,
    IN p_id_petugas INT,
    IN p_tanggal_kembali DATETIME
)
BEGIN
    DECLARE v_status VARCHAR(20);
    DECLARE v_ada INT DEFAULT 0;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT COUNT(*)
    INTO v_ada
    FROM peminjaman
    WHERE id_peminjaman = p_id_peminjaman;

    IF v_ada = 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Peminjaman tidak ditemukan';
    END IF;

    SELECT status
    INTO v_status
    FROM peminjaman
    WHERE id_peminjaman = p_id_peminjaman
    FOR UPDATE;

    IF v_status NOT IN ('disetujui', 'dipinjam') THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Status peminjaman tidak dapat dikembalikan';
    END IF;

    SELECT COUNT(*)
    INTO v_ada
    FROM pengembalian
    WHERE id_peminjaman = p_id_peminjaman;

    IF v_ada > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Peminjaman sudah dikembalikan';
    END IF;

    INSERT INTO pengembalian (
        id_peminjaman,
        id_petugas,
        tanggal_kembali,
        denda
    )
    VALUES (
        p_id_peminjaman,
        p_id_petugas,
        p_tanggal_kembali,
        0
    );

    COMMIT;

    SELECT id_pengembalian, id_peminjaman, tanggal_kembali, denda
    FROM pengembalian
    WHERE id_peminjaman = p_id_peminjaman;
END//


DROP PROCEDURE IF EXISTS sp_riwayat_peminjaman_user//

CREATE PROCEDURE sp_riwayat_peminjaman_user(
    IN p_nim_nip VARCHAR(30)
)
BEGIN
    SELECT
        pg.nim_nip,
        pg.nama AS nama_pengguna,
        p.id_peminjaman,
        p.keperluan,
        p.tanggal_pengajuan,
        p.tanggal_digunakan,
        p.tanggal_selesai,
        p.status,
        a.nama_aset,
        dp.jumlah,
        peng.tanggal_kembali,
        peng.denda
    FROM pengguna pg
    JOIN peminjaman p
        ON pg.id_pengguna = p.id_pengguna
    JOIN detail_peminjaman dp
        ON p.id_peminjaman = dp.id_peminjaman
    JOIN aset a
        ON dp.id_aset = a.id_aset
    LEFT JOIN pengembalian peng
        ON p.id_peminjaman = peng.id_peminjaman
    WHERE pg.nim_nip = p_nim_nip
    ORDER BY p.tanggal_pengajuan DESC;
END//

DELIMITER ;