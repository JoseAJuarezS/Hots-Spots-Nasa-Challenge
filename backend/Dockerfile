# Backend (FastAPI + DuckDB) con uv.
FROM python:3.15-slim
COPY --from=ghcr.io/astral-sh/uv:0.13.8 /uv /uvx /bin/
WORKDIR /app

# Primero solo las dependencias, para aprovechar la caché de capas
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-install-project

COPY . .
RUN uv sync --frozen

# Ruta de la base DuckDB dentro del contenedor (se monta desde analisis/)
ENV DUCKDB_PATH=/datos/focos.duckdb
EXPOSE 8000
CMD ["uv", "run", "fastapi", "run", "app/main.py", "--host", "0.0.0.0", "--port", "8000"]
