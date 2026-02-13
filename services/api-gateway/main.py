import os
import json
import asyncio
from fastapi import FastAPI, HTTPException, Depends
from pydantic import BaseModel
from typing import List, Optional
import aio_pika
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
from sqlalchemy.orm import sessionmaker
from sqlalchemy import text

RABBITMQ_URL = os.getenv("BROKER_URL", "amqp://admin:simulation_secure@rabbitmq:5672/")
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql+asyncpg://admin:password@db/swiss_twin")

app = FastAPI(title="Swiss Digital Twin API")

engine = create_async_engine(DATABASE_URL, echo=False)
async_session = sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

async def get_db():
    async with async_session() as session:
        yield session

mq_connection = None
mq_channel = None

@app.on_event("startup")
async def startup():
    global mq_connection, mq_channel
    mq_connection = await aio_pika.connect_robust(RABBITMQ_URL)
    mq_channel = await mq_connection.channel()
    await mq_channel.declare_queue("simulation_queue", durable=True)

@app.on_event("shutdown")
async def shutdown():
    await mq_connection.close()

class AvalancheSimRequest(BaseModel):
    lat: float
    lon: float

@app.get("/health")
async def health():
    return {"status": "operational", "engine": "FastAPI"}

@app.post("/simulate/avalanche")
async def trigger_simulation(req: AvalancheSimRequest):
    """Envoie une demande de simulation au worker via RabbitMQ."""
    message_body = json.dumps(req.dict()).encode()
    
    await mq_channel.default_exchange.publish(
        aio_pika.Message(
            body=message_body,
            delivery_mode=aio_pika.DeliveryMode.PERSISTENT
        ),
        routing_key="simulation_queue"
    )
    
    return {"message": "Simulation queued", "location": [req.lat, req.lon]}

@app.get("/data/stations")
async def get_stations_data(db: AsyncSession = Depends(get_db)):
    """Récupère les dernières données IMIS (neige) depuis TimescaleDB."""
    query = text("""
        SELECT station_id, location, snow_depth, temperature, timestamp 
        FROM imis_data 
        ORDER BY timestamp DESC 
        LIMIT 50
    """)
    result = await db.execute(query)
    stations = result.fetchall()
    
    return [
        {
            "id": s[0], 
            "coords": s[1], 
            "snow": s[2], 
            "temp": s[3], 
            "time": s[4]
        } for s in stations
    ]

@app.get("/data/roads/risks")
async def get_road_risks(db: AsyncSession = Depends(get_db)):
    """Requête spatiale : identifie les segments de route en zone de danger."""
    query = text("""
        SELECT r.name, r.importance, ST_AsGeoJSON(r.geom) 
        FROM roads r
        JOIN avalanche_zones z ON ST_Intersects(r.geom, z.geom)
        WHERE z.risk_level > 3
    """)
    result = await db.execute(query)
    return result.fetchall()
