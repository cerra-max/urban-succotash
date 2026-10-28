# 用于支持 Docker 的平台（Koyeb、Hugging Face Spaces 等）
FROM python:3.12-slim
WORKDIR /app
COPY server.py index.html ./
ENV PORT=8787 PYTHONUNBUFFERED=1
EXPOSE 8787
CMD ["python3", "server.py", "--host", "0.0.0.0"]
