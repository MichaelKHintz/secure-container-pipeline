from fastapi import FastAPI

# Interactive docs disabled: less unauthenticated surface.
app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)

@app.get("/healthz")
def health() -> dict[str, str]:
    return {"status": "ok"}
