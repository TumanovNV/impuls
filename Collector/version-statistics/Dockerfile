FROM python:3.13-slim

RUN useradd --system --uid 10001 --create-home collector
WORKDIR /app
COPY --chown=collector:collector collector.py report.py README.md ./
USER collector
ENV IMPULS_TELEMETRY_HOST=0.0.0.0 \
    IMPULS_TELEMETRY_PORT=8080 \
    IMPULS_TELEMETRY_DATABASE=/data/version-statistics.sqlite3
EXPOSE 8080
CMD ["python3", "/app/collector.py"]
