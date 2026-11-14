"""API inferensi demo UTS SBDT: OIDC JWKS, primary write, replica read."""
import os
from pathlib import Path
from functools import lru_cache
import joblib
import jwt
from jwt import PyJWKClient
import psycopg
from psycopg.rows import dict_row
from fastapi import FastAPI, HTTPException, Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field

app = FastAPI(title='UTS SBDT - Inference API', version='1.0.0')
auth_scheme = HTTPBearer(auto_error=True)

@lru_cache

def load_model():
    return joblib.load(os.getenv('MODEL_PATH', '/app/model/model.joblib'))

@lru_cache

def jwks_client():
    url = os.environ['OIDC_JWKS_URL']
    return PyJWKClient(url, cache_keys=True, lifespan=300)


def current_user(credentials: HTTPAuthorizationCredentials = Depends(auth_scheme)) -> dict:
    token = credentials.credentials
    try:
        public_key = jwks_client().get_signing_key_from_jwt(token).key
        claims = jwt.decode(
            token, public_key, algorithms=['RS256'],
            audience=os.environ['OIDC_AUDIENCE'],
            issuer=os.environ['OIDC_ISSUER'],
            options={'require': ['exp', 'iss', 'sub', 'aud']},
        )
        return claims
    except (jwt.PyJWTError, jwt.PyJWKClientError, KeyError, ValueError) as exc:
        raise HTTPException(status_code=401, detail='JWT tidak valid') from exc


def db_connection(readonly: bool = False):
    # Routing dilakukan oleh backend menggunakan DNS service; tidak menyimpan alamat IP pod.
    return psycopg.connect(
        host=os.environ['DB_HOST_READ' if readonly else 'DB_HOST_WRITE'],
        port=int(os.getenv('DB_PORT', '5432')),
        dbname=os.environ['POSTGRES_DB'],
        user=os.environ['POSTGRES_USER'],
        password=os.environ['POSTGRES_PASSWORD'],
        connect_timeout=8,
        row_factory=dict_row,
    )

class TransactionFeatures(BaseModel):
    nominal: float = Field(ge=0, le=1_000_000_000)
    gagal_login: int = Field(ge=0, le=100)
    usia_akun_hari: int = Field(ge=0, le=100_000)
    jam_transaksi: int = Field(ge=0, le=23)

@app.get('/health')
def health():
    return {'status': 'up', 'model': 'synthetic-logreg-v1'}

@app.post('/predict')
def predict(payload: TransactionFeatures, user: dict = Depends(current_user)):
    record = [payload.nominal, payload.gagal_login, payload.usia_akun_hari, payload.jam_transaksi]
    risk = float(load_model()['model'].predict_proba([record])[0, 1])
    label = 'tinggi' if risk >= 0.5 else 'rendah'
    with db_connection(readonly=False) as conn:
        with conn.cursor() as cur:
            cur.execute("""INSERT INTO hasil_inferensi
                (user_sub, nominal, gagal_login, usia_akun_hari, jam_transaksi, skor_risiko, label_risiko)
                VALUES (%s,%s,%s,%s,%s,%s,%s)
                RETURNING id, created_at""",
                (user['sub'], *record, risk, label))
            created = cur.fetchone()
    return {'id': created['id'], 'skor_risiko': round(risk, 5), 'label': label,
            'write_node': 'primary', 'created_at': created['created_at'].isoformat(),
            'catatan': 'Hanya model pendidikan; bukan penilaian risiko finansial nyata'}

@app.get('/history')
def history(user: dict = Depends(current_user)):
    with db_connection(readonly=True) as conn:
        with conn.cursor() as cur:
            cur.execute('SELECT pg_is_in_recovery() AS is_standby')
            standby = bool(cur.fetchone()['is_standby'])
            if not standby:
                raise HTTPException(status_code=503, detail='Read endpoint bukan standby')
            cur.execute("""SELECT id, nominal, gagal_login, usia_akun_hari,
                jam_transaksi, skor_risiko, label_risiko, created_at
                FROM hasil_inferensi WHERE user_sub=%s ORDER BY id DESC LIMIT 30""", (user['sub'],))
            rows = cur.fetchall()
    for r in rows:
        r['created_at'] = r['created_at'].isoformat()
    return {'read_node': 'standby', 'standby_confirmed': standby, 'items': rows,
            'catatan': 'Replikasi asynchronous: hasil baru bisa muncul sesaat kemudian'}

@app.get('/db/topology')
def topology(user: dict = Depends(current_user)):
    def role(readonly):
        with db_connection(readonly=readonly) as conn:
            with conn.cursor() as cur:
                cur.execute('SELECT pg_is_in_recovery() AS standby')
                return 'standby' if cur.fetchone()['standby'] else 'primary'
    return {'write_connection': role(False), 'read_connection': role(True)}
