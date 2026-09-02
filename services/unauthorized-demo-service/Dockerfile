FROM registry.access.redhat.com/ubi9/python-312:latest
LABEL org.opencontainers.image.base.name="registry.access.redhat.com/ubi9/python-312:latest" \
      demo.rhacs.ai/base-image-owner="messaging-platform" \
      demo.rhacs.ai/application-owner="security-demo"
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /opt/app-root/src
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
EXPOSE 8080
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
