# syntax=docker/dockerfile:1

# Build stage: same Python version and Debian release as the runtime, so compiled wheels (pydantic-core) match the runtime ABI.
FROM python:3.13-slim-trixie@sha256:3dd7cc108ec1493442514f5c2a871af6af0ec31d768ff6e378a93340c3b3db5f AS build
WORKDIR /build
COPY app/requirements.txt .
RUN pip install --no-cache-dir --target /build/deps -r requirements.txt

# Runtime stage: no shell, no package manager, non-root user.
FROM gcr.io/distroless/python3-debian13:nonroot@sha256:774595d652a294b54c9bd575b2d9fdd1a4b47547dc17b8bfa4c0e953c64855b3
LABEL org.opencontainers.image.source="https://github.com/MichaelKHintz/secure-container-pipeline"
WORKDIR /app
ENV PYTHONPATH=/app/deps \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
COPY --from=build /build/deps /app/deps
COPY app/main.py /app/main.py
USER 65532:65532
EXPOSE 8000
ENTRYPOINT ["python3", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
