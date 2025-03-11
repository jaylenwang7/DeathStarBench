#!/usr/bin/env python3
import aiohttp
import asyncio
import argparse
import time
from datetime import datetime

async def register_movie(session, server_addr, movie_id, title):
    params = {
        "title": f"title_{movie_id}",
        "movie_id": f"movie_id_{movie_id}"
    }
    async with session.post(f"{server_addr}/wrk2-api/movie/register", data=params) as resp:
        return await resp.text()

async def main(server_addr):
    start_time = time.time()
    start_timestamp = datetime.now().strftime("%m/%d %H:%M:%S")
    print(f"Started registering movies at {start_timestamp}")
    
    tasks = []
    conn = aiohttp.TCPConnector(limit=200)
    async with aiohttp.ClientSession(connector=conn) as session:
        for i in range(1, 1001):
            task = asyncio.ensure_future(register_movie(session, server_addr, i, f"title_{i}"))
            tasks.append(task)
            if i % 200 == 0:
                responses = await asyncio.gather(*tasks)
                print(f"{i} movies registered")
                tasks = []
        
        if tasks:
            responses = await asyncio.gather(*tasks)
            print("All movies registered")
    
    end_time = time.time()
    duration = end_time - start_time
    print(f"Completed in {duration:.2f} seconds")

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument("--server_address", action="store", dest="server_addr",
        type=str, default="http://127.0.0.1:30080")
    args = parser.parse_args()

    loop = asyncio.get_event_loop()
    future = asyncio.ensure_future(main(args.server_addr))
    loop.run_until_complete(future) 