# Multi-stage: dependensi + model dibangun terpisah dari runtime aplikasi.
FROM python:3.12-slim AS builder
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt
COPY app/train_model.py /build/train_model.py
RUN PYTHONPATH=/install/lib/python3.12/site-packages python /build/train_model.py --output /build/model.joblib

FROM python:3.12-slim AS runtime
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY --from=builder /install /usr/local
COPY --from=builder /build/model.joblib /app/model/model.joblib
COPY app/ /app/app/
RUN useradd -u 10001 -r -s /usr/sbin/nologin appuser && chown -R appuser:appuser /app
USER 10001
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
