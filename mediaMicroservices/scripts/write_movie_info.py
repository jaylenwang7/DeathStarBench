#!/usr/bin/env python3
import aiohttp
import asyncio
import sys
import json
import argparse
import time
from datetime import datetime

async def upload_cast_info(session, addr, cast):
  # Ensure all fields are properly typed strings
  cast_data = {
    "cast_info_id": str(cast["cast_info_id"]),
    "name": str(cast["name"]) if cast["name"] else "",
    "gender": "true" if cast["gender"] else "false",  # Convert boolean to string
    "intro": str(cast["intro"]) if cast["intro"] else ""
  }
  async with session.post(addr + "/wrk2-api/cast-info/write", json=cast_data) as resp:
    return await resp.text()

async def upload_plot(session, addr, plot):
  plot_data = {
    "plot_id": plot["plot_id"],
    "plot": plot["plot"]
  }
  async with session.post(addr + "/wrk2-api/plot/write", json=plot_data) as resp:
    return await resp.text()

async def upload_movie_info(session, addr, movie):
  # Helper function to safely handle list items, filtering out None values
  def safe_list(items):
    if items is None:
      return []
    return [str(item) for item in items if item is not None]

  # Convert movie dict to proper JSON format
  json_data = {
    "movie_id": movie["movie_id"],
    "title": movie["title"],
    "plot_id": str(movie["plot_id"]),
    "thumbnail_ids": safe_list(movie["thumbnail_ids"]),
    "photo_ids": safe_list(movie["photo_ids"]),
    "video_ids": safe_list(movie["video_ids"]),
    "avg_rating": float(movie["avg_rating"]),
    "num_rating": int(movie["num_rating"]),
    "casts": movie["casts"]   
  }
  async with session.post(addr + "/wrk2-api/movie-info/write", json=json_data) as resp:
    return await resp.text()

async def register_movie(session, addr, movie):
  form_data = {
    "title": movie["title"],
    "movie_id": str(movie["movie_id"])
  }
  headers = {
    "Content-Type": "application/x-www-form-urlencoded"
  }
  async with session.post(addr + "/wrk2-api/movie/register", data=form_data, headers=headers) as resp:
    return await resp.text()

async def write_cast_info(addr, raw_casts):
  idx = 0
  tasks = []
  conn = aiohttp.TCPConnector(limit=200)
  async with aiohttp.ClientSession(connector=conn) as session:
    for raw_cast in raw_casts:
      try:
        cast = dict()
        cast["cast_info_id"] = raw_cast["id"]
        cast["name"] = raw_cast["name"] if raw_cast.get("name") else ""
        cast["gender"] = True if raw_cast.get("gender") == 2 else False
        cast["intro"] = raw_cast["biography"] if raw_cast.get("biography") else ""
        task = asyncio.ensure_future(upload_cast_info(session, addr, cast))
        tasks.append(task)
        idx += 1
      except Exception as e:
        print(f"Warning: cast info missing or invalid! Error: {str(e)}")
        continue
      if idx % 200 == 0:
        try:
          resps = await asyncio.gather(*tasks)
          print(idx, "casts finished")
          tasks = []  # Clear tasks after processing batch
        except Exception as e:
          print(f"Error processing batch at index {idx}: {str(e)}")
          tasks = []  # Clear failed tasks
    if tasks:  # Process any remaining tasks
      try:
        resps = await asyncio.gather(*tasks)
        print(idx, "casts finished")
      except Exception as e:
        print(f"Error processing final batch: {str(e)}")

async def write_movie_info(addr, raw_movies):
  idx = 0
  tasks = []
  conn = aiohttp.TCPConnector(limit=200)
  async with aiohttp.ClientSession(connector=conn) as session:
    for raw_movie in raw_movies:
      movie = dict()
      casts = list()
      movie["movie_id"] = str(raw_movie["id"])
      movie["title"] = raw_movie["title"]
      movie["plot_id"] = raw_movie["id"]
      for raw_cast in raw_movie["cast"]:
        try:
          cast = dict()
          cast["cast_id"] = raw_cast["cast_id"]
          cast["character"] = raw_cast["character"]
          cast["cast_info_id"] = raw_cast["id"]
          casts.append(cast)
        except:
          print("Warning: cast info missing!")
      movie["casts"] = casts
      movie["thumbnail_ids"] = [raw_movie["poster_path"]]
      movie["photo_ids"] = []
      movie["video_ids"] = []
      movie["avg_rating"] = raw_movie["vote_average"]
      movie["num_rating"] = raw_movie["vote_count"]
      task = asyncio.ensure_future(upload_movie_info(session, addr, movie))
      tasks.append(task)
      plot = dict()
      plot["plot_id"] = raw_movie["id"]
      plot["plot"] = raw_movie["overview"]
      task = asyncio.ensure_future(upload_plot(session, addr, plot))
      tasks.append(task)
      task = asyncio.ensure_future(register_movie(session, addr, movie))
      tasks.append(task)
      idx += 1
      if idx % 200 == 0:
        resps = await asyncio.gather(*tasks)
        print(idx, "movies finished")
    resps = await asyncio.gather(*tasks)
    print(idx, "movies finished")

if __name__ == '__main__':
  parser = argparse.ArgumentParser()
  parser.add_argument("-c", "--cast", action="store", dest="cast_filename",
    type=str, default="../datasets/tmdb/casts.json")
  parser.add_argument("-m", "--movie", action="store", dest="movie_filename",
    type=str, default="../datasets/tmdb/movies.json")
  parser.add_argument("--server_address", action="store", dest="server_addr",
    type=str, default="http://127.0.0.1:30080")
  args = parser.parse_args()

  start_time = time.time()
  start_timestamp = datetime.now().strftime("%m/%d %H:%M:%S")
  print(f"Started processing at {start_timestamp}")

  with open(args.cast_filename, 'r') as cast_file:
    raw_casts = json.load(cast_file)
  loop = asyncio.get_event_loop()
  future = asyncio.ensure_future(write_cast_info(args.server_addr, raw_casts))
  loop.run_until_complete(future)

  with open(args.movie_filename, 'r') as movie_file:
    raw_movies = json.load(movie_file)
    loop = asyncio.get_event_loop()
    future = asyncio.ensure_future(write_movie_info(args.server_addr, raw_movies))
    loop.run_until_complete(future)
  
  end_time = time.time()
  duration = end_time - start_time
  print(f"Completed in {duration:.2f} seconds")