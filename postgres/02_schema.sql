CREATE TABLE IF NOT EXISTS hasil_inferensi (
    id BIGSERIAL PRIMARY KEY,
    user_sub TEXT NOT NULL,
    nominal DOUBLE PRECISION NOT NULL,
    gagal_login INTEGER NOT NULL,
    usia_akun_hari INTEGER NOT NULL,
    jam_transaksi INTEGER NOT NULL,
    skor_risiko DOUBLE PRECISION NOT NULL,
    label_risiko TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_hasil_user ON hasil_inferensi(user_sub, id DESC);
