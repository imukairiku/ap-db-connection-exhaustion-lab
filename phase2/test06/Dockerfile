FROM python:3.12-alpine
RUN pip install --no-cache-dir psycopg2-binary==2.9.9
COPY app.py hold-admin.py /app/
WORKDIR /app
CMD ["python3", "app.py"]
