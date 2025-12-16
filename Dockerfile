FROM python:3.11-slim

# Install system dependencies (if any)
RUN apt-get update -y && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements and install
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Copy source code
COPY src ./src

# Set PYTHONPATH so that `src` is discoverable
ENV PYTHONPATH=/app/src

# Entrypoint accepts JOB_NAME to determine which task to run
ENTRYPOINT ["python", "-m", "src.main"]
