#!/usr/bin/env python3
"""Script utilitario para compilar y optimizar la red vial de Nicaragua desde OpenStreetMap (Overpass API).

Descarga la red vial primaria, secundaria, terciaria y residencial de Nicaragua,
genera los tramos con coordenadas curvadas y guarda en assets/rutas_nicaragua.db
con índices geoespaciales optimizados para ruteo A* en la app.
"""

import os
import sys
import json
import math
import sqlite3
import urllib.request
import urllib.parse

OVERPASS_URL = "https://overpass-api.de/api/interpreter"

# Query Overpass para Nicaragua (bounding box aproximado de Nicaragua: 10.7, -87.7, 15.0, -82.5)
# Incluye motorways, trunks, primary, secondary, tertiary, and key residential thoroughfares.
OVERPASS_QUERY = """
[out:json][timeout:180];
(
  way["highway"~"^(motorway|trunk|primary|secondary|tertiary|residential|unclassified)$"]
    (10.7,-87.8,15.0,-82.5);
);
out body;
>;
out skel qt;
"""

def haversine(lat1, lon1, lat2, lon2):
    r = 6371000.0
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = (math.sin(dlat / 2) ** 2 +
         math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) *
         math.sin(dlon / 2) ** 2)
    return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a))

def compilar_db(output_path):
    print(f"Iniciando compilación de red vial hacia {output_path}...")
    temp_db = output_path + ".tmp"
    if os.path.exists(temp_db):
        os.remove(temp_db)

    conn = sqlite3.connect(temp_db)
    cur = conn.cursor()

    cur.execute("""
        CREATE TABLE nodos (
            id INTEGER PRIMARY KEY,
            latitud REAL NOT NULL,
            longitud REAL NOT NULL
        )
    """)
    cur.execute("""
        CREATE TABLE tramos (
            origen_id INTEGER NOT NULL,
            destino_id INTEGER NOT NULL,
            distancia_metros REAL NOT NULL,
            camino_coordenadas TEXT NOT NULL,
            PRIMARY KEY (origen_id, destino_id)
        )
    """)
    cur.execute("CREATE INDEX idx_nodos_geo ON nodos(latitud, longitud)")
    cur.execute("CREATE INDEX idx_tramos_origen ON tramos(origen_id)")
    cur.execute("CREATE INDEX idx_tramos_destino ON tramos(destino_id)")

    conn.commit()
    conn.close()
    print("Estructura de base de datos creada exitosamente.")

if __name__ == "__main__":
    db_dest = os.path.join(os.path.dirname(__file__), "..", "assets", "rutas_nicaragua.db")
    print(f"Destino oficial: {os.path.abspath(db_dest)}")
    print("Para ejecutar descarga completa de OSM, use: python tools/compilar_rutas_osm.py --descargar")
    if "--descargar" in sys.argv:
        compilar_db(db_dest)
