import os, threading
import psycopg2

connections=[]
for index in range(2):
    connection=psycopg2.connect(host=os.environ['DB_HOST'],user='lab',password='lab-only',dbname='lab',application_name=f'management-{index+1}')
    connection.cursor().execute('SELECT 1'); connections.append(connection)
print('MANAGEMENT_CONNECTIONS_READY=2',flush=True)
threading.Event().wait()
