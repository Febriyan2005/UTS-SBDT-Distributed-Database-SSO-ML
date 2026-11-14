"""Model demo skor risiko transaksi, dilatih pada DATA SINTETIS.
Bukan model perbankan produksi; tidak punya klaim akurasi dunia nyata.
"""
import argparse
from pathlib import Path
import joblib
import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

def train(output: str):
    rng = np.random.default_rng(2026)
    n = 1600
    amount = rng.uniform(10000, 25000000, n)
    failures = rng.integers(0, 7, n)
    age_days = rng.integers(1, 2500, n)
    hour = rng.integers(0, 24, n)
    x = np.column_stack([amount, failures, age_days, hour])
    # Label sintetis menggunakan aturan eksplisit + sedikit gangguan.
    score = 1.7 * (amount > 10000000) + 1.2 * (failures >= 3) \
          + 0.8 * (age_days < 30) + 0.65 * ((hour < 5) | (hour > 22)) \
          + rng.normal(0, 0.45, n)
    y = (score >= 1.65).astype(int)
    pipeline = Pipeline([
        ('scaler', StandardScaler()),
        ('classifier', LogisticRegression(max_iter=1500, random_state=2026)),
    ])
    pipeline.fit(x, y)
    out = Path(output)
    out.parent.mkdir(parents=True, exist_ok=True)
    joblib.dump({'model': pipeline, 'version':'synthetic-logreg-v1', 'training_data':'synthetic'}, out)
    print(f'Model demo disimpan di {out}; pelatihan dengan {n} contoh sintetis.')

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--output', default='model/model.joblib')
    train(ap.parse_args().output)
