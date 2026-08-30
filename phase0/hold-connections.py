import signal
import time

import psycopg2

running = True


def stop(_signum, _frame):
    global running
    running = False


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
connections = []
while len(connections) < 3:
    try:
        connection = psycopg2.connect(
            host="db",
            user="probe",
            password="probe-only",
            dbname="probe",
            application_name="ap-server-1",
        )
        connection.autocommit = False
        connection.cursor().execute("SELECT 1")
        connections.append(connection)
    except psycopg2.Error:
        time.sleep(1)

while running:
    time.sleep(1)

for connection in connections:
    connection.close()
