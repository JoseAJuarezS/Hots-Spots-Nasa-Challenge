from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(title="Hot Spots API")

# Permite que el frontend de Vite (puerto 5173) llame a la API en desarrollo
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/salud")
def salud():
    return {"estado": "ok"}
