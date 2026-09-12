import datetime
import json
import os
import pathlib
import threading
import time

import psycopg2

START = pathlib.Path('/tmp/start-retry')
REQUEST_ID = os.environ['REQUEST_ID']

def emit(event, **extra):
    print(json.dumps({'at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                      'monotonic': time.monotonic(), 'event': event,
                      'request_id': REQUEST_ID, **extra}), flush=True)

emit('READY', connect_timeout=5)
while not START.exists():
    time.sleep(.1)

attempt = 0
while True:
    attempt += 1
    started = time.monotonic()
    emit('CONNECT_ATTEMPT', attempt=attempt)
    try:
        connection = psycopg2.connect(host=os.environ['DB_HOST'], user='app_user',
                                      password='app-only', dbname='lab',
                                      application_name='ap-server-2', connect_timeout=5)
        emit('DB_CONNECTED', attempt=attempt)
        with connection:
            with connection.cursor() as cursor:
                cursor.execute('INSERT INTO business_results(request_id,ap_name) VALUES(%s,%s)',
                               (REQUEST_ID, 'ap-server-2'))
        connection.close()
        emit('BUSINESS_COMMITTED', attempt=attempt)
        break
    except psycopg2.OperationalError as error:
        emit('CONNECT_FAILED', attempt=attempt, elapsed_seconds=round(time.monotonic()-started, 3),
             error_type=type(error).__name__, db_error=str(error).strip())
        delay = min(2 ** (attempt - 1), 4)
        before = time.monotonic()
        emit('BACKOFF_START', attempt=attempt, seconds=delay)
        time.sleep(delay)
        emit('BACKOFF_END', attempt=attempt, elapsed_seconds=round(time.monotonic()-before, 3))

threading.Event().wait()
