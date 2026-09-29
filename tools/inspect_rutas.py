import sqlite3

con = sqlite3.connect('assets/rutas_nicaragua.db')
cur = con.cursor()
cur.execute("SELECT name, sql FROM sqlite_master WHERE type='index'")
for r in cur.fetchall():
    print("Indice:", r)
